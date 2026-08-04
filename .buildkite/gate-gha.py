#!/usr/bin/env python3
"""Gate a release candidate on litellm's GitHub Actions required checks.

Reads the required contexts from the same ruleset that governs merges into
litellm_internal_staging, so the gate can never drift from what the repo
actually enforces.

Fails closed. A required check that is absent is treated exactly like a
failing one: on a public repo an untested commit reports as an empty list,
not as a failure, and "no data" must never read as "nothing wrong".
"""

from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = os.environ.get("GATE_REPO", "BerriAI/litellm")
RULESET_ID = os.environ.get("GATE_RULESET_ID", "17360296")
DEADLINE_SECONDS = int(os.environ.get("GATE_DEADLINE_SECONDS", "3600"))
POLL_SECONDS = int(os.environ.get("GATE_POLL_SECONDS", "30"))
TERMINAL = frozenset({"success", "failure", "cancelled", "timed_out", "action_required", "neutral", "skipped", "stale"})


def api(path: str) -> object:
    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if not token:
        sys.exit("GITHUB_TOKEN is not set; cannot query check runs")
    req = urllib.request.Request(
        f"https://api.github.com{path}",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "litellm-release-gate",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"GitHub API {exc.code} on {path}: {exc.read()[:300].decode('utf-8', 'replace')}")


def required_contexts() -> tuple[str, ...]:
    ruleset = api(f"/repos/{REPO}/rulesets/{RULESET_ID}")
    assert isinstance(ruleset, dict)
    for rule in ruleset.get("rules", []):
        if rule.get("type") == "required_status_checks":
            checks = rule["parameters"]["required_status_checks"]
            return tuple(sorted(c["context"] for c in checks))
    sys.exit(f"ruleset {RULESET_ID} declares no required_status_checks")


def conclusions_for(sha: str) -> dict[str, str]:
    """Latest conclusion (or in-flight status) per check name."""
    runs: list[dict[str, object]] = []
    for page in range(1, 6):
        payload = api(f"/repos/{REPO}/commits/{sha}/check-runs?per_page=100&page={page}")
        assert isinstance(payload, dict)
        batch = payload.get("check_runs") or []
        runs.extend(batch)
        if len(batch) < 100:
            break
    # A check can run more than once (re-runs); the newest started wins.
    newest: dict[str, dict[str, object]] = {}
    for run in sorted(runs, key=lambda r: str(r.get("started_at") or "")):
        newest[str(run["name"])] = run
    return {name: str(r.get("conclusion") or r.get("status") or "unknown") for name, r in newest.items()}


def annotate(style: str, body: str) -> None:
    if not os.environ.get("BUILDKITE"):
        return
    os.system(f"buildkite-agent annotate {json.dumps(body)} --style {style} --context gate-gha")


def main() -> int:
    if len(sys.argv) != 2 or not sys.argv[1].strip():
        return int(bool(sys.stderr.write("usage: gate-gha.py <sha>\n"))) or 2
    sha = sys.argv[1].strip()

    required = required_contexts()
    print(f"gate: {len(required)} required checks from ruleset {RULESET_ID}")
    print(f"gate: commit {sha}")

    deadline = time.monotonic() + DEADLINE_SECONDS
    while True:
        seen = conclusions_for(sha)
        missing = tuple(c for c in required if c not in seen)
        pending = tuple(c for c in required if c in seen and seen[c] not in TERMINAL)

        if not pending and not missing:
            break
        if time.monotonic() >= deadline:
            print(f"gate: deadline reached after {DEADLINE_SECONDS}s", file=sys.stderr)
            break
        print(f"gate: waiting — {len(pending)} in flight, {len(missing)} not started")
        time.sleep(POLL_SECONDS)

    seen = conclusions_for(sha)
    missing = tuple(c for c in required if c not in seen)
    failed = tuple(c for c in required if c in seen and seen[c] != "success" and seen[c] != "skipped")
    passed = tuple(c for c in required if seen.get(c) in ("success", "skipped"))

    print(f"\ngate: {len(passed)}/{len(required)} required checks passed")
    for c in failed:
        print(f"  FAILED   {c} -> {seen[c]}")
    for c in missing:
        print(f"  MISSING  {c}  (never ran for this commit)")

    if failed or missing:
        lines = [f"**GHA gate failed for `{sha[:10]}`**\n"]
        lines += [f"- failed: `{c}` ({seen[c]})" for c in failed]
        lines += [f"- missing: `{c}` — never ran for this commit" for c in missing]
        annotate("error", "\n".join(lines))
        return 1

    annotate("success", f"**GHA gate passed for `{sha[:10]}`** — {len(passed)}/{len(required)} required checks green")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
