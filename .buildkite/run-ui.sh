#!/usr/bin/env bash
set -euo pipefail

TEST_PATH="${1:?usage: run-ui.sh <test-path-under-src>}"

cd ui/litellm-dashboard

echo "--- :package: npm ci"
npm ci --no-audit --no-fund

echo "--- :test_tube: vitest ${TEST_PATH}"
CI=true npx vitest run "${TEST_PATH}" \
  --pool forks \
  --poolOptions.forks.maxForks=4 \
  --reporter=default \
  --reporter=junit \
  --outputFile.junit=junit-ui.xml
