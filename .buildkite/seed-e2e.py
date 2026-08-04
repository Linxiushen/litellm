#!/usr/bin/env python3
"""Idempotent environment seeder for the ephemeral per-SHA e2e stack.

Runs between deploy-ephemeral and e2e-run. Reads the declarative manifest
.buildkite/e2e-seed.yaml (JSON-syntax YAML subset; full-line # comments are
stripped so the manifest stays self-documenting while stdlib json parses it)
and registers every listed model that is absent from /v1/model/info via
/model/new, exactly like the Admin UI would. Entries already present by
model_name are skipped, so re-runs are no-ops. Never a pg_dump of stage.

Doubles as the admin-plane readiness gate for the run: a proxy that cannot
answer /v1/model/info with the master key fails here in seconds instead of
40 minutes into the suite.

PoC home is the pipeline dir; the make-it-right home for the manifest is
tests/e2e/environment/ in the litellm repo, baked into the e2e runner image,
so a test that starts expecting new ambient state updates the manifest in
the same commit.
"""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

MANIFEST = os.environ.get("E2E_SEED_MANIFEST", ".buildkite/e2e-seed.yaml")
PROXY = os.environ.get("LITELLM_PROXY_URL", "").rstrip("/")
MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")


def api(method: str, path: str, body: object | None = None) -> object:
    payload = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"{PROXY}{path}",
        data=payload,
        method=method,
        headers={
            "Authorization": f"Bearer {MASTER_KEY}",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        sys.exit(f"{method} {path} -> HTTP {exc.code}: {exc.read()[:300].decode('utf-8', 'replace')}")
    except urllib.error.URLError as exc:
        sys.exit(f"{method} {path} unreachable: {exc.reason}")


def main() -> int:
    if not PROXY or not MASTER_KEY:
        sys.exit("LITELLM_PROXY_URL and LITELLM_MASTER_KEY must be set")

    with open(MANIFEST, encoding="utf-8") as fh:
        source = "".join(line for line in fh if not line.lstrip().startswith("#"))
    manifest = json.loads(source)
    wanted = manifest.get("models", [])
    print(f"seed: manifest {MANIFEST} lists {len(wanted)} model(s)")

    info = api("GET", "/v1/model/info")
    assert isinstance(info, dict)
    existing = frozenset(m.get("model_name", "") for m in info.get("data", []))
    print(f"seed: proxy reports {len(existing)} existing model name(s)")

    created = tuple(
        entry["model_name"]
        for entry in wanted
        if entry["model_name"] not in existing
        and api("POST", "/model/new", entry) is not None
    )
    skipped = tuple(e["model_name"] for e in wanted if e["model_name"] in existing)

    for name in skipped:
        print(f"seed: skip {name} (already present)")
    for name in created:
        print(f"seed: created {name}")
    print(f"seed: done ({len(created)} created, {len(skipped)} skipped)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
