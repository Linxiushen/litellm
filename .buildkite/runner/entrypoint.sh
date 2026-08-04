#!/usr/bin/env sh
# Run the e2e suite from its own rootdir so pytest.ini + the flat-module
# imports (from e2e_config import ...) resolve. Any args are forwarded to
# pytest, so the chart can pass suite selection (-k / a subdir), -v, etc.
#
# Two prod-readiness behaviors beyond a bare `pytest`:
#
# 1. Proxy preflight. The suite's own conftest follows "skip on environment,
#    fail on behavior" — if the proxy is unreachable it SKIPS and the process
#    exits 0. For an unattended Job that silently green-passes a misconfigured
#    target, which is the opposite of what you want from an e2e gate. So when
#    REQUIRE_PROXY=1 (default) we probe the proxy first and FAIL loudly if it
#    is unreachable. Set REQUIRE_PROXY=0 to restore pure skip-on-environment.
#
# 2. Optional dry-run mode. TEST_MODE=dry-run collects pytest node IDs, runs the
#    first DRY_RUN_TEST_COUNT tests, then still emits the coverage collector
#    output. This is a quick smoke path for validating Loki ingestion without
#    waiting for the full e2e suite.
#
# 3. `-p no:cacheprovider` so pytest never writes .pytest_cache into the
#    (read-only) image filesystem. Keeps the container compatible with
#    readOnlyRootFilesystem: true (Pod Security Standards "restricted").
#    https://kubernetes.io/docs/concepts/security/pod-security-standards/
#
# 4. Writable paths under /tmp for Claude Code matrix artifacts. The chart
#    mounts only /tmp as emptyDir; cwd (/app/e2e) is read-only, so the
#    default relative `compat-results.json` would raise OSError: [Errno 30].
#
# 5. Optional Playwright UI suite. tests/e2e/ui is a TypeScript package pytest
#    cannot collect, so RUN_UI_TESTS=1 runs it after pytest and folds its exit
#    code into the job's. Default off; see the guard below for why.
set -eu

: "${LITELLM_PROXY_URL:?LITELLM_PROXY_URL must be set}"
: "${REQUIRE_PROXY:=1}"
: "${TEST_MODE:=full}"
: "${DRY_RUN_TEST_COUNT:=3}"
: "${TMPDIR:=/tmp}"
: "${RUN_UI_TESTS:=1}"
: "${COMPAT_RESULTS_PATH:=/tmp/compat-results.json}"
: "${COMPAT_RATE_LIMIT_SUMMARY_PATH:=/tmp/compat-rate-limit-summary.json}"
: "${LITELLM_COMPAT_RATE_STATE_DIR:=/tmp/litellm-claude-compat-ratelimit}"
# /home/e2e is not writable under readOnlyRootFilesystem; keep a HOME on /tmp.
: "${HOME:=/tmp/e2e-home}"
# Always write JUnit under /tmp so release-gate scrapers (Buildkite kubectl cp,
# CronJob log tools) can collect node ids without relying on chart extraArgs.
: "${E2E_ARTIFACT_DIR:=/tmp/e2e-artifacts}"
: "${E2E_JUNIT_PATH:=${E2E_ARTIFACT_DIR}/junit.xml}"
# Buildkite Test Engine ingest. The Job runs in a private VPC with no inbound
# path, and its pod (restartPolicy: Never, emptyDir /tmp) is gone before anything
# outside could read the JUnit, so results are PUSHED out over egress rather than
# scraped. Unset token -> upload is skipped and the run behaves exactly as before.
: "${BUILDKITE_ANALYTICS_URL:=https://analytics-api.buildkite.com/v1/uploads}"
: "${BUILDKITE_ANALYTICS_TOKEN:=}"

export TMPDIR
export HOME
export COMPAT_RESULTS_PATH
export COMPAT_RATE_LIMIT_SUMMARY_PATH
export LITELLM_COMPAT_RATE_STATE_DIR
export E2E_ARTIFACT_DIR
export E2E_JUNIT_PATH
export BUILDKITE_ANALYTICS_URL
export BUILDKITE_ANALYTICS_TOKEN
mkdir -p "${HOME}" "${LITELLM_COMPAT_RATE_STATE_DIR}" "${TMPDIR}/playwright-state" "${E2E_ARTIFACT_DIR}"

# Ship whatever JUnit exists to Test Engine on the way out, whichever exit path
# we take. A FAILING run's results are the ones the release gate most needs, so
# this cannot hang off the success path. Upload problems are logged but never
# change the job's exit status: the gate fails closed on missing results, so a
# silent upload failure reads as "did not pass", never as a false green.
upload_results_on_exit() {
  _rc=$?
  trap - EXIT
  python - <<'PY' || echo "test-engine: uploader crashed; results not shipped" >&2
import os
import sys

token = os.environ.get("BUILDKITE_ANALYTICS_TOKEN", "").strip()
if not token:
    print("test-engine: BUILDKITE_ANALYTICS_TOKEN unset; skipping upload")
    raise SystemExit(0)

junit = os.environ["E2E_JUNIT_PATH"]
if not os.path.exists(junit):
    print(f"test-engine: no JUnit at {junit}; nothing to upload", file=sys.stderr)
    raise SystemExit(0)

import requests

try:
    with open("/app/e2e/.litellm-revision") as fh:
        revision = fh.read().strip()
except OSError:
    revision = "unknown"

# Pod name is unique per Job run, so re-running the same commit stays a distinct
# run while commit_sha keeps every run for a SHA queryable by the gate.
run_key = os.environ.get("E2E_RUN_KEY") or f"{revision}-{os.environ.get('HOSTNAME', 'job')}"

with open(junit, "rb") as fh:
    resp = requests.post(
        os.environ["BUILDKITE_ANALYTICS_URL"],
        headers={"Authorization": f'Token token="{token}"'},
        files={"data": ("junit.xml", fh, "application/xml")},
        data={
            "format": "junit",
            "run_env[CI]": "generic",
            "run_env[key]": run_key,
            "run_env[commit_sha]": revision,
        },
        timeout=60,
    )

print(f"test-engine: revision={revision} run_key={run_key}")
print(f"test-engine: upload -> HTTP {resp.status_code} {resp.text[:500]}")
if resp.status_code >= 400:
    raise SystemExit(1)
PY
  exit "${_rc}"
}
trap upload_results_on_exit EXIT

cd /app/e2e

case "${TEST_MODE}" in
  full | dry-run) ;;
  *)
    echo "TEST_MODE must be 'full' or 'dry-run', got '${TEST_MODE}'" >&2
    exit 2
    ;;
esac

# Fail early if the image lost the Claude Code CLI. The claude_code matrix
# cannot run without it; a missing binary previously red'd ~74 cells in ~10s.
if ! command -v claude >/dev/null 2>&1; then
  echo "preflight: claude CLI not on PATH (install @anthropic-ai/claude-code in the image)" >&2
  exit 2
fi
echo "preflight: claude CLI present ($(claude --version 2>/dev/null || echo unknown))"

if [ "${REQUIRE_PROXY}" = "1" ]; then
  # Same liveness endpoint the suite's conftest uses, but here a failure is
  # fatal instead of a skip. `requests` is already installed for the suite. In a
  # split deployment the management/admin control plane (LITELLM_CONTROL_PLANE_URL)
  # is a separate service, so probe it too when set — else its tests would fail
  # loudly mid-run instead of the proxy surfacing as unreachable up front.
  python - <<'PY'
import os
import sys

import requests

targets = [("proxy", os.environ["LITELLM_PROXY_URL"])]
control = os.environ.get("LITELLM_CONTROL_PLANE_URL", "").strip()
if control and control.rstrip("/") != os.environ["LITELLM_PROXY_URL"].rstrip("/"):
    targets.append(("control plane", control))

for label, base in targets:
    url = base.rstrip("/") + "/health/liveliness"
    try:
        resp = requests.get(url, timeout=10)
    except requests.RequestException as exc:
        sys.exit(
            f"preflight: {label} unreachable at {url}: {exc}\n"
            "Set REQUIRE_PROXY=0 to treat an unreachable target as a skip instead."
        )
    if resp.status_code >= 500:
        sys.exit(f"preflight: {label} at {url} returned {resp.status_code}")
    print(f"preflight: {label} reachable at {url} ({resp.status_code})")
PY
fi

run_pytest() {
  if [ "${TEST_MODE}" != "dry-run" ]; then
    pytest -p no:cacheprovider --junitxml="${E2E_JUNIT_PATH}" "$@"
    return $?
  fi

  python - "${DRY_RUN_TEST_COUNT}" "${E2E_JUNIT_PATH}" "$@" <<'PY'
import subprocess
import sys

try:
    test_count = int(sys.argv[1])
except ValueError:
    sys.exit(f"DRY_RUN_TEST_COUNT must be an integer, got {sys.argv[1]!r}")

junit_path = sys.argv[2]

if test_count < 1:
    sys.exit("DRY_RUN_TEST_COUNT must be at least 1")

pytest_args = sys.argv[3:]
collect_args = [
    arg
    for arg in pytest_args
    if arg not in ("-v", "--verbose", "-q", "--quiet")
    and not (arg.startswith("-") and set(arg[1:]) <= {"v"})
    and not (arg.startswith("-") and set(arg[1:]) <= {"q"})
]
collect_cmd = [
    "pytest",
    "-p",
    "no:cacheprovider",
    "--collect-only",
    "-q",
    *collect_args,
]

print(f"dry-run: collecting tests with: {' '.join(collect_cmd)}", flush=True)
collect = subprocess.run(collect_cmd, capture_output=True, text=True)
if collect.returncode != 0:
    sys.stdout.write(collect.stdout)
    sys.stderr.write(collect.stderr)
    sys.exit(collect.returncode)

node_ids = [
    line.strip()
    for line in collect.stdout.splitlines()
    if "::" in line and not line.lstrip().startswith("<")
]
selected = node_ids[:test_count]
if not selected:
    sys.stdout.write(collect.stdout)
    sys.exit("dry-run: pytest collection found no runnable tests")

print(f"dry-run: running {len(selected)} of {len(node_ids)} collected tests", flush=True)
for node_id in selected:
    print(f"dry-run: selected {node_id}", flush=True)

run_cmd = [
    "pytest",
    "-p",
    "no:cacheprovider",
    f"--junitxml={junit_path}",
    *pytest_args,
    *selected,
]
sys.exit(subprocess.call(run_cmd))
PY
}

set +e
run_pytest "$@"
pytest_status=$?
set -e

# Playwright UI suite. tests/e2e/ui is a self-contained TypeScript package with
# its own package-lock.json and @playwright/test, so pytest cannot collect it
# and it never ran from this entrypoint at all — not even as a skip.
#
# The suite reads LITELLM_PROXY_URL for its base URL and self-seeds the password
# users it logs in as, so it can target this deployment. PLAYWRIGHT_STATE_DIR
# keeps its storage-state files off the read-only cwd. Set RUN_UI_TESTS=0 to skip
# it and leave the job pytest-only.
ui_status=0
if [ "${RUN_UI_TESTS}" = "1" ]; then
  if [ "${TEST_MODE}" = "dry-run" ]; then
    echo "ui: skipped (TEST_MODE=dry-run is a pytest/Loki smoke path)"
  elif [ ! -d /app/e2e/ui/node_modules ]; then
    # The image build's `npm ci` is guarded on the suite existing at that ref.
    echo "ui: skipped (/app/e2e/ui/node_modules missing; image built from a ref without tests/e2e/ui)"
  else
    echo "ui: running playwright suite"
    # cwd is read-only, so every playwright artifact has to land under TMPDIR.
    # The configured html reporter would write playwright-report/ into the image
    # and is unreadable in a pod log, so report to stdout instead.
    set +e
    (
      cd /app/e2e/ui \
        && PLAYWRIGHT_STATE_DIR="${TMPDIR}/playwright-state" \
           PLAYWRIGHT_HTML_OUTPUT_DIR="${TMPDIR}/playwright-report" \
           npx playwright test \
             --config playwright.config.ts \
             --reporter=list \
             --output="${TMPDIR}/playwright-artifacts"
    )
    ui_status=$?
    set -e
    echo "ui: playwright exited ${ui_status}"
  fi
fi

# Emit coverage lines into the same pod stdout/Loki stream as pytest. Keep this
# best-effort so collector issues do not mask or create e2e failures.
PYTHONPATH=. python -m coverage_registry.collector --format loki || true

# Surface pytest first since it is the primary gate, but never let a UI failure
# exit 0.
if [ "${pytest_status}" -ne 0 ]; then
  exit "${pytest_status}"
fi
exit "${ui_status}"
