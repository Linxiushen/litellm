#!/usr/bin/env bash
# Ensures litellm-e2e:e2e-<sha> exists in ECR: skip if present, else build
# from the bundled litellm-auto Dockerfile (.buildkite/runner/, snapshot
# commit in runner/.litellm-auto-revision) with LITELLM_REF=<sha> and push.
# Unlike build-image.sh there is no nightly re-tag path: nightly tags
# (1.0.0-main.<ts>) do not encode the litellm SHA they baked, so a re-tag
# could silently attach the wrong test code to the SHA.
#
# After pushing, the baked /app/e2e/.litellm-revision is compared to the
# requested SHA; on mismatch the tag is deleted and the step fails, so
# e2e-run (which depends on this step) can never consume a wrongly-baked
# image. That file is what the entrypoint uploads to Test Engine as
# run_env[commit_sha], making per-SHA attribution a verified guarantee.
# Verify-after-push (not before) because the agents' default buildx builder
# is a REMOTE driver: without --push/--load the result stays in the build
# cache and never lands in the local daemon, and --load would shuttle the
# multi-GB image through the agent twice. The verify pull also proves the
# tag is pullable, which is exactly what e2e-run is about to do.
set -euo pipefail

SHA="${1:?usage: build-runner-image.sh <litellm-sha>}"
if ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "expected a full 40-char lowercase SHA, got: $SHA" >&2
  exit 1
fi

REGION="us-east-1"
REGISTRY="654278500801.dkr.ecr.us-east-1.amazonaws.com"
REPO="litellm-e2e"
TARGET_TAG="e2e-${SHA}"
AWSCLI_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.36.15@sha256:310813a7eae8fd88da1cc9c37970e3500b0ff3984479e1012f0a6fd44e453f63"

if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  AWS_ACCESS_KEY_ID="$(buildkite-agent secret get AWS_ACCESS_KEY_ID)"
  AWS_SECRET_ACCESS_KEY="$(buildkite-agent secret get AWS_SECRET_ACCESS_KEY)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
fi

ecr() {
  docker run --rm \
    -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN \
    -e AWS_DEFAULT_REGION="$REGION" \
    "$AWSCLI_IMAGE" ecr "$@"
}

echo "--- :mag: does ${REPO}:${TARGET_TAG} already exist?"
if out="$(ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TARGET_TAG" 2>&1)"; then
  echo "already present; nothing to do"
  printf '%s\n' "$out" | grep -o '"imageDigest": "[^"]*"' | head -n1
  exit 0
fi
case "$out" in
  *ImageNotFoundException*) echo "not present yet" ;;
  *)
    printf '%s\n' "$out" >&2
    exit 1
    ;;
esac

echo "--- :docker: docker login ${REGISTRY}"
ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

echo "--- :docker: build + push ${REPO}:${TARGET_TAG} (LITELLM_REF=${SHA})"
DOCKER_BUILDKIT=1 docker build \
  --platform linux/amd64 \
  --push \
  --build-arg "LITELLM_REF=${SHA}" \
  -t "${REGISTRY}/${REPO}:${TARGET_TAG}" \
  .buildkite/runner

echo "--- :dna: verify baked .litellm-revision == ${SHA}"
baked="$(docker run --rm --entrypoint cat "${REGISTRY}/${REPO}:${TARGET_TAG}" /app/e2e/.litellm-revision)"
if [ "$baked" != "$SHA" ]; then
  echo "baked revision '${baked}' != requested SHA; deleting the tag" >&2
  ecr batch-delete-image --repository-name "$REPO" --image-ids imageTag="$TARGET_TAG"
  exit 1
fi
echo "baked revision matches"

echo "--- :white_check_mark: verify tag is visible in ECR"
ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TARGET_TAG" \
  --query 'imageDetails[0].{tags:imageTags,digest:imageDigest,pushedAt:imagePushedAt}' --output json
