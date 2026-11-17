#!/usr/bin/env bash
# Builds the MCP server image and pushes it to ACR.
# BUILD_MODE: auto (ACR Tasks, falling back to local Docker), acr, or local.
set -euo pipefail

: "${ACR_NAME:?}" "${IMAGE:?}" "${SOURCE_DIR:?}" "${SUBSCRIPTION_ID:?}"
BUILD_MODE="${BUILD_MODE:-auto}"

acr_build() {
  echo "Building $IMAGE with ACR Tasks in $ACR_NAME ..."
  az acr build --subscription "$SUBSCRIPTION_ID" --registry "$ACR_NAME" \
    --image "$IMAGE" --platform linux/amd64 "$SOURCE_DIR"
}

local_build() {
  echo "Building $IMAGE with local Docker and pushing to $ACR_NAME ..."
  local login_server
  login_server="$(az acr show --subscription "$SUBSCRIPTION_ID" --name "$ACR_NAME" --query loginServer -o tsv)"
  az acr login --subscription "$SUBSCRIPTION_ID" --name "$ACR_NAME"

  local build_args=()
  if [[ -n "${PYPI_INDEX_URL:-}" ]]; then
    build_args=(--build-arg "PYPI_INDEX_URL=$PYPI_INDEX_URL")
  fi
  docker buildx build --platform linux/amd64 ${build_args[@]+"${build_args[@]}"} \
    --tag "$login_server/$IMAGE" --push "$SOURCE_DIR"
}

case "$BUILD_MODE" in
  acr) acr_build ;;
  local) local_build ;;
  auto) acr_build || { echo "ACR Tasks build failed; falling back to local Docker." >&2; local_build; } ;;
  *) echo "Unknown BUILD_MODE '$BUILD_MODE' (expected auto, acr or local)." >&2; exit 1 ;;
esac
