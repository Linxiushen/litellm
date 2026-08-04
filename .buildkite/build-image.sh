#!/usr/bin/env bash
set -euo pipefail

SHA="${1:?usage: build-image.sh <litellm-sha>}"
if ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{40}$'; then
  echo "expected a full 40-char lowercase SHA, got: $SHA" >&2
  exit 1
fi

REGION="us-east-1"
REGISTRY="654278500801.dkr.ecr.us-east-1.amazonaws.com"
REPO="litellm/gateway"
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

echo "--- :mag: can an existing branch-*-<shortsha> tag be re-tagged?"
match=""
for tag in $(ecr list-images --repository-name "$REPO" --filter tagStatus=TAGGED \
    --query 'imageIds[].imageTag' --output text | tr '\t' '\n'); do
  suffix="${tag##*-}"
  if printf '%s' "$suffix" | grep -qE '^[0-9a-f]{7,40}$' \
      && [ "${SHA#"$suffix"}" != "$SHA" ]; then
    match="$tag"
    break
  fi
done

if [ -n "$match" ]; then
  echo "re-tagging ${REPO}:${match} as ${TARGET_TAG}"
  manifest="$(ecr batch-get-image --repository-name "$REPO" --image-ids imageTag="$match" \
    --query 'images[0].imageManifest' --output text)"
  if [ -z "$manifest" ] || [ "$manifest" = "None" ]; then
    echo "batch-get-image returned no manifest for ${match}" >&2
    exit 1
  fi
  ecr put-image --repository-name "$REPO" --image-tag "$TARGET_TAG" \
    --image-manifest "$manifest" --query 'image.imageId' --output json
  echo "re-tag complete"
  exit 0
fi

echo "--- :git: no existing image; fetching BerriAI/litellm @ ${SHA}"
src="$(mktemp -d)/litellm"
git init -q "$src"
git -C "$src" remote add origin https://github.com/BerriAI/litellm.git
git -C "$src" fetch --depth 1 origin "$SHA"
git -C "$src" checkout -q FETCH_HEAD
if [ ! -f "$src/gateway/Dockerfile" ]; then
  echo "gateway/Dockerfile does not exist at ${SHA}; cannot build" >&2
  exit 1
fi

echo "--- :docker: docker login ${REGISTRY}"
ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"

echo "--- :docker: build + push ${REPO}:${TARGET_TAG}"
DOCKER_BUILDKIT=1 docker build \
  --platform linux/amd64 \
  --push \
  -f "$src/gateway/Dockerfile" \
  -t "${REGISTRY}/${REPO}:${TARGET_TAG}" \
  "$src"

echo "--- :white_check_mark: verify tag is visible in ECR"
ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TARGET_TAG" \
  --query 'imageDetails[0].{tags:imageTags,digest:imageDigest,pushedAt:imagePushedAt}' --output json
