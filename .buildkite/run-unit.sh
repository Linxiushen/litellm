#!/usr/bin/env bash
set -euo pipefail

TEST_PATH="${1:?usage: run-unit.sh <test-path> [workers]}"
WORKERS="${2:-2}"
SUITE="$(printf '%s' "${TEST_PATH}" | tr '/' '-')"

echo "--- :arrow_down: uv 0.10.9"
curl -LsSf -o /tmp/uv-install.sh https://astral.sh/uv/0.10.9/install.sh
echo "7fc46e39cb97290b57169c0c813a17970585ac519139f19006453c99b5f2f45f  /tmp/uv-install.sh" | sha256sum -c -
env UV_NO_MODIFY_PATH=1 sh /tmp/uv-install.sh
export PATH="${HOME}/.local/bin:${PATH}"
rm -f /tmp/uv-install.sh

echo "--- :package: dependencies"
.github/scripts/uv_sync_with_retries.sh \
  --frozen --group ci --group proxy-dev \
  --extra google --extra proxy --extra semantic-router --extra saml

echo "--- :database: prisma client"
uv run --no-sync prisma generate --schema litellm/proxy/schema.prisma

echo "--- :test_tube: pytest ${TEST_PATH}"
uv run --no-sync pytest "${TEST_PATH}" \
  --tb=short -vv \
  --maxfail=10 \
  -n "${WORKERS}" \
  --reruns 2 \
  --reruns-delay 1 \
  --dist=loadscope \
  --durations=20 \
  --junitxml="junit-${SUITE}.xml"
