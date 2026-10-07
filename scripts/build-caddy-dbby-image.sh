#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: build-caddy-dbby-image.sh --platforms PLATFORMS [--target TARGET]
       [--tag IMAGE:TAG] [--load | --push | --output EXPORT]
       [--metadata-file FILE]

PLATFORMS is a Buildx platform list, for example linux/amd64 or
linux/amd64,linux/arm64,linux/arm/v7,linux/arm/v6. The helper passes the
locked provenance arguments to Dockerfile.caddy and disables implicit build
attestations. It is intended for the manually reviewed DBBY release workflow.
EOF
}

platforms=
target=runtime
tag=
output=
metadata_file=
mode=
while (($#)); do
  case "$1" in
    --platforms)
      (($# >= 2)) || { usage; exit 2; }
      platforms=$2
      shift 2
      ;;
    --target)
      (($# >= 2)) || { usage; exit 2; }
      target=$2
      shift 2
      ;;
    --tag)
      (($# >= 2)) || { usage; exit 2; }
      tag=$2
      shift 2
      ;;
    --load)
      [ -z "$mode" ] || { echo "choose only one of --load, --push, or --output" >&2; exit 2; }
      mode=load
      shift
      ;;
    --push)
      [ -z "$mode" ] || { echo "choose only one of --load, --push, or --output" >&2; exit 2; }
      mode=push
      shift
      ;;
    --output)
      (($# >= 2)) || { usage; exit 2; }
      [ -z "$mode" ] || { echo "choose only one of --load, --push, or --output" >&2; exit 2; }
      mode=output
      output=$2
      shift 2
      ;;
    --metadata-file)
      (($# >= 2)) || { usage; exit 2; }
      metadata_file=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$platforms" ] || { usage; exit 2; }
[ -d source/outlinecaddy ] || { echo "source/outlinecaddy is missing" >&2; exit 1; }
[ -x scripts/build-caddy-dbby.sh ] || { echo "shared build script is not executable" >&2; exit 1; }

for name in SOURCE_REPOSITORY SOURCE_TAG SOURCE_SHA SOURCE_DATE SOURCE_DATE_EPOCH \
  UPSTREAM_BASE_SHA OUTLINE_SERVER_VERSION OUTLINE_SERVER_SHA CADDY_VERSION CADDY_SHA GO_VERSION \
  OUTLINE_SERVER_MODULE_ORIGIN CADDY_MODULE_ORIGIN \
  GO_BUILDER_IMAGE CADDY_RUNTIME_IMAGE BINARY_VERSION IMAGE_VERSION \
  WRAPPER_REPOSITORY WRAPPER_SHA; do
  if [[ -z "${!name:-}" ]]; then
    echo "missing required build environment variable: $name" >&2
    exit 1
  fi
done

build_script_sha=$(sha256sum scripts/build-caddy-dbby.sh | awk '{print $1}')

build_args=(
  --build-arg "SOURCE_REPOSITORY=$SOURCE_REPOSITORY"
  --build-arg "SOURCE_TAG=$SOURCE_TAG"
  --build-arg "SOURCE_SHA=$SOURCE_SHA"
  --build-arg "SOURCE_DATE=$SOURCE_DATE"
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
  --build-arg "UPSTREAM_BASE_SHA=$UPSTREAM_BASE_SHA"
  --build-arg "OUTLINE_SERVER_VERSION=$OUTLINE_SERVER_VERSION"
  --build-arg "OUTLINE_SERVER_SHA=$OUTLINE_SERVER_SHA"
  --build-arg "OUTLINE_SERVER_MODULE_ORIGIN=$OUTLINE_SERVER_MODULE_ORIGIN"
  --build-arg "CADDY_VERSION=$CADDY_VERSION"
  --build-arg "CADDY_SHA=$CADDY_SHA"
  --build-arg "CADDY_MODULE_ORIGIN=$CADDY_MODULE_ORIGIN"
  --build-arg "GO_VERSION=$GO_VERSION"
  --build-arg "GO_IMAGE=$GO_BUILDER_IMAGE"
  --build-arg "RUNTIME_IMAGE=$CADDY_RUNTIME_IMAGE"
  --build-arg "WRAPPER_REPOSITORY=$WRAPPER_REPOSITORY"
  --build-arg "WRAPPER_SHA=$WRAPPER_SHA"
  --build-arg "BUILD_SCRIPT_SHA=$build_script_sha"
  --build-arg "BINARY_VERSION=$BINARY_VERSION"
  --build-arg "IMAGE_VERSION=$IMAGE_VERSION"
)

command=(docker buildx build --progress=plain --provenance=false
  --file Dockerfile.caddy --platform "$platforms" --target "$target"
  "${build_args[@]}"
)
if [[ -n "$tag" ]]; then
  command+=(--tag "$tag")
fi
case "$mode" in
  load) command+=(--load) ;;
  push) command+=(--push) ;;
  output) command+=(--output "$output") ;;
  '') ;;
esac
if [[ -n "$metadata_file" ]]; then
  command+=(--metadata-file "$metadata_file")
fi
command+=(.)
printf 'buildx_command='; printf '%q ' "${command[@]}"; printf '\n'
"${command[@]}"
