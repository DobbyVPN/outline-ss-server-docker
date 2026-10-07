#!/bin/sh
set -eu

usage() {
  cat >&2 <<'EOF'
Usage: build-caddy-dbby.sh --source-dir DIR --output FILE --arch ARCH [--variant VARIANT]

ARCH is one of amd64, arm64, or arm. For arm, VARIANT must be v6 or v7.
The script builds the pinned Outline Caddy submodule without changing its
module graph or using a workspace. It intentionally uses POSIX shell so the
official Alpine Go builder does not need an extra shell package.
EOF
}

source_dir=
output=
arch=
variant=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      source_dir=$2
      shift 2
      ;;
    --output)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      output=$2
      shift 2
      ;;
    --arch)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      arch=$2
      shift 2
      ;;
    --variant)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      variant=$2
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

if [ -z "$source_dir" ] || [ -z "$output" ] || [ -z "$arch" ]; then
  usage
  exit 2
fi

source_dir=$(CDPATH= cd -- "$source_dir" && pwd -P)
module_dir=$source_dir/outlinecaddy
test -f "$module_dir/go.mod"
test -f "$module_dir/cmd/caddy/main.go"
test -f "$source_dir/LICENSE"

expected_go_version=${EXPECTED_GO_VERSION:-1.26.8}
expected_caddy_version=${EXPECTED_CADDY_VERSION:-v2.11.7}
expected_server_version=${EXPECTED_OUTLINE_SERVER_VERSION:-v1.9.3-rc2}
binary_version=${BINARY_VERSION:-v2.11.7-dbby}

actual_go_version=$(go version | awk '{print $3}' | sed 's/^go//')
if [ "$actual_go_version" != "$expected_go_version" ]; then
  echo "Go toolchain is $actual_go_version; expected $expected_go_version" >&2
  exit 1
fi

cd "$module_dir"
actual_caddy_version=$(GOWORK=off GOTOOLCHAIN=local go list -mod=readonly -m -f '{{.Version}}' github.com/caddyserver/caddy/v2)
actual_server_version=$(GOWORK=off GOTOOLCHAIN=local go list -mod=readonly -m -f '{{.Version}}' golang.getoutline.org/tunnel-server)
if [ "$actual_caddy_version" != "$expected_caddy_version" ]; then
  echo "Caddy module is $actual_caddy_version; expected $expected_caddy_version" >&2
  exit 1
fi
if [ "$actual_server_version" != "$expected_server_version" ]; then
  echo "Outline server module is $actual_server_version; expected $expected_server_version" >&2
  exit 1
fi

goarch=$arch
goarm=
goamd64=
case "$arch-$variant" in
  amd64-)
    goarch=amd64
    goamd64=v1
    ;;
  arm64-)
    goarch=arm64
    ;;
  arm-v7)
    goarch=arm
    goarm=7
    ;;
  arm-v6)
    goarch=arm
    goarm=6
    ;;
  *)
    echo "unsupported target architecture: $arch${variant:+/$variant}" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$output")"
set -- CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" GOWORK=off GOTOOLCHAIN=local
if [ -n "$goarm" ]; then
  set -- "$@" GOARM="$goarm"
fi
if [ -n "$goamd64" ]; then
  set -- "$@" GOAMD64="$goamd64"
fi

ldflags="-s -w -buildid= -X github.com/caddyserver/caddy/v2.CustomVersion=$binary_version"
env "$@" go build \
  -mod=readonly \
  -trimpath \
  -buildvcs=false \
  -tags=nomysql \
  -ldflags="$ldflags" \
  -o "$output" \
  ./cmd/caddy
chmod 0755 "$output"
echo "built=$output"
echo "go_version=$actual_go_version"
echo "caddy_module_version=$actual_caddy_version"
echo "outline_server_module_version=$actual_server_version"
echo "target=linux/$goarch${goarm:+/v$goarm}${goamd64:+/v$goamd64}"
