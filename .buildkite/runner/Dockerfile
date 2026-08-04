# syntax=docker/dockerfile:1.7
#
# Packages the LiteLLM end-to-end test suite (tests/e2e/ from the litellm
# repo) into a self-contained runner image. The suite is a pytest suite that
# drives a *running* LiteLLM proxy over HTTP; it needs no provider keys of its
# own (those live on the target proxy). Point it at a proxy with
# LITELLM_PROXY_URL + LITELLM_MASTER_KEY and run.
#
# The tests are pulled from the litellm repo at build time so the nightly
# rebuild always ships the latest suite. Override the ref to build a PR or pinned
# SHA, e.g. --build-arg LITELLM_REF=pull/12345/head.
#
# Deps are resolved from litellm's own uv.lock (not a hand-kept pinned list) so
# this runner can never drift from what the suite imports -- the gap that let a
# missing `websockets` wedge collection. We `uv sync --no-install-workspace`,
# which installs the locked dependencies but skips building the first-party
# packages: the suite drives a remote proxy over HTTP and never imports litellm.

ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.12@sha256:3a59a3cdd5f7c217faa36e32dbc7fddbb0412889c2a0a5229f6d790e5a019dd7
# Node 22 (multi-arch index). Used to install the Claude Code CLI and to
# provide npm/npx for the tests/e2e/ui TypeScript Playwright package; the
# runtime image stays python:3.13-slim-trixie and receives a selective copy.
ARG NODE_IMAGE=node:22.17.1-bookworm-slim@sha256:2fa754a9ba4d7adbd2a51d182eaabbe355c82b673624035a38c0d42b08724854

##########  uv binary  ##########
FROM ${UV_IMAGE} AS uvbin

##########  Node stage: Claude Code CLI + npm/npx  ##########
# The claude_code matrix shells out to the real `claude` binary. Without it
# every CLI-driven cell fails in milliseconds with ClaudeCLIError. Install in
# a Node stage so we never mix npm's /usr/local with CPython's. This stage
# also supplies the npm/npx binaries the runtime copies over, so tests/e2e/ui
# (a self-contained npm package, not part of the uv workspace) can `npm ci`.
FROM ${NODE_IMAGE} AS claude-cli

# No version pin: the image rebuilds every 6h and should track the CLI the
# suite is written against. Override with e.g. --build-arg CLAUDE_CODE_VERSION=2.1.211
# only when you need to reproduce an old run.
ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && claude --version

##########  fetch the suite  ##########
FROM python:3.13-slim-trixie AS fetch

ARG LITELLM_REPO=https://github.com/BerriAI/litellm.git
# Any fetchable ref works: a branch (`litellm_internal_staging`, `main`), tag,
# full SHA, or a PR head (`pull/12345/head`). Defaults to internal staging, where
# the e2e suite + gateway config live.
ARG LITELLM_REF=litellm_internal_staging

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
# Sparse, shallow fetch at the requested ref. `git fetch` (vs `clone --branch`)
# accepts PR refs and SHAs, not only named branches. Beyond tests/e2e we pull the
# workspace members (enterprise, litellm-proxy-extras) so `uv sync` can resolve
# the whole workspace; cone mode also brings every root file (pyproject.toml,
# uv.lock, README.md), which is what the sync reads.
RUN git init litellm \
    && cd litellm \
    && git remote add origin "${LITELLM_REPO}" \
    && git sparse-checkout init --cone \
    && git sparse-checkout set tests/e2e enterprise litellm-proxy-extras \
    && git fetch --depth 1 origin "${LITELLM_REF}" \
    && git checkout FETCH_HEAD \
    && test -d tests/e2e \
    && mkdir -p /out \
    && cp -r tests/e2e /out/e2e \
    && cp pyproject.toml uv.lock README.md /out/ \
    && cp -r enterprise litellm-proxy-extras /out/ \
    && (git rev-parse HEAD > /out/e2e/.litellm-revision || true)

##########  runtime  ##########
FROM python:3.13-slim-trixie AS runtime

# OCI image annotations for provenance/discoverability.
# https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="litellm-e2e" \
      org.opencontainers.image.description="LiteLLM end-to-end test suite runner" \
      org.opencontainers.image.source="https://github.com/berriai/litellm-auto" \
      org.opencontainers.image.licenses="MIT"

COPY --from=uvbin /uv /uvx /usr/local/bin/

# Non-root. uid 10001 avoids clashing with common host uids.
RUN useradd --system --uid 10001 --create-home --home-dir /home/e2e e2e

# UV_COMPILE_BYTECODE=1  precompiles .pyc at install time -> faster cold start.
# UV_LINK_MODE=copy      avoids hardlink warnings across the cache-mount fs.
# UV_PYTHON_DOWNLOADS=0  use the image's CPython, don't pull a managed one.
#
# Claude Code matrix artifacts and rate-limit state default under /tmp so the
# chart's readOnlyRootFilesystem + emptyDir on /tmp can accept them (cwd is
# /app/e2e and is not writable).
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0 \
    VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    LITELLM_PROXY_URL=http://localhost:4000 \
    LITELLM_MASTER_KEY=sk-1234 \
    REQUIRE_PROXY=1 \
    LITELLM_USE_RUST_OCR=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    TMPDIR=/tmp \
    HOME=/tmp/e2e-home \
    COMPAT_RESULTS_PATH=/tmp/compat-results.json \
    COMPAT_RATE_LIMIT_SUMMARY_PATH=/tmp/compat-rate-limit-summary.json \
    LITELLM_COMPAT_RATE_STATE_DIR=/tmp/litellm-claude-compat-ratelimit
WORKDIR /app

# The suite's deps come from litellm's locked workspace. The imports it actually
# uses live across two extras: websockets + pyyaml (proxy), requests (cli);
# pydantic is a base dep and pytest comes from the default `dev` group. --frozen
# reuses uv.lock as-is; --no-install-workspace keeps litellm itself out of the
# runner. Versions float with the daily clone, in lockstep with the suite.
#
# redis (the spend-counter reseed test's client) is installed separately: litellm
# only exposes it transitively behind the extra_proxy -> redisvl -> ml-dtypes
# stack, which drags a compiled ML numerics chain into a runner that just needs a
# pure-python redis client. Pinned to the version uv.lock resolves for parity.
#
# pipecat-ai is not in litellm's lock at all: the realtime pipecat tests guard it
# with `pytest.importorskip("pipecat")`, so without it they skip silently instead
# of running. The [openai] extra covers the pipecat.services.openai.realtime
# imports the suite uses. Pinned since there's no lockfile to float with; note
# litellm's `exclude-newer = "3 days"` (pyproject [tool.uv]) applies here too, so
# a pin only resolves once the release is >3 days old.
#
# The e2e-dev group carries playwright at litellm's locked version; without it
# the management UI suite (test_key_models_dropdown_e2e.py) module-skips via
# importorskip and the dashboard coverage never runs.
COPY --from=fetch /out/pyproject.toml /out/uv.lock /out/README.md ./
COPY --from=fetch /out/enterprise ./enterprise
COPY --from=fetch /out/litellm-proxy-extras ./litellm-proxy-extras
RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --frozen --no-install-workspace --python python3.13 \
        --extra proxy --extra cli --group e2e-dev \
    && uv pip install redis==7.4.1 hiredis==3.4.0 prometheus-client "pipecat-ai[openai]==1.4.0"

# Chromium for the playwright UI tests. PLAYWRIGHT_BROWSERS_PATH (set above,
# and read again at runtime) moves the browser out of /root/.cache so the
# non-root e2e user can read it; --with-deps installs chromium's system
# libraries while we are still root. No cache mount: the download must land in
# the image layer. Runtime writes (chromium's profile) go under /tmp, which the
# chart mounts as an emptyDir, so readOnlyRootFilesystem still holds.
RUN playwright install --with-deps chromium \
    && chmod -R a+rX /ms-playwright \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI: selective copy so we do not clobber CPython under /usr/local.
# The package ships a native platform binary via optional deps; node stays on
# PATH for the npm shim and any node-spawned helpers.
COPY --from=claude-cli /usr/local/bin/node /usr/local/bin/node
COPY --from=claude-cli /usr/local/bin/claude /usr/local/bin/claude
COPY --from=claude-cli /usr/local/lib/node_modules /usr/local/lib/node_modules
# Recreate the npm/npx launchers so the tests/e2e/ui package can `npm ci`. They
# are symlinks into node_modules/npm (copied above); COPY would dereference them
# into plain files and break npm-cli.js's relative require, so link them instead.
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
    && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
    && claude --version && npm --version

COPY --from=fetch --chown=e2e:e2e /out/e2e /app/e2e

# tests/e2e/ui is a self-contained TypeScript Playwright package outside the uv
# workspace, pinned to its own @playwright/test (see its package-lock.json). Its
# browser build is keyed to that version, which differs from the Python
# playwright above, so install it separately from the suite's own lockfile into
# the shared PLAYWRIGHT_BROWSERS_PATH. Chromium's system libraries were already
# installed by the Python `playwright install --with-deps` step, so this only
# fetches the browser binary. Done while root; re-chmod so the non-root e2e user
# can read the new revision.
#
# Guarded because the suite only exists on litellm refs that carry tests/e2e/ui;
# on a ref without it there is nothing to run, and the build must stay green.
RUN if [ -d /app/e2e/ui ]; then \
        cd /app/e2e/ui \
        && npm ci \
        && npx playwright install chromium \
        && chmod -R a+rX /ms-playwright; \
    else \
        echo "tests/e2e/ui not present at this litellm ref; skipping npm ci + browser install"; \
    fi
COPY entrypoint.sh /usr/local/bin/run-e2e
RUN chmod +x /usr/local/bin/run-e2e

USER e2e

# Default: run the whole suite. The Helm chart / `docker run ... -- -k foo`
# can append pytest args (suite selection, -v, -k, etc.).
ENTRYPOINT ["run-e2e"]
CMD ["-v"]
