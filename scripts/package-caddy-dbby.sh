#!/usr/bin/env bash
set -euo pipefail

if (($# != 4)); then
  echo "Usage: package-caddy-dbby.sh SOURCE_DIR BINARY OUT_DIR SOURCE_DATE_EPOCH" >&2
  exit 2
fi

source_dir="$(cd "$1" && pwd -P)"
binary="$(cd "$(dirname "$2")" && pwd -P)/$(basename "$2")"
out_dir="$3"
source_epoch="$4"
version="${BINARY_VERSION:-v2.11.7-r2-dbby}"
version_no_v="${version#v}"
archive="caddy_${version_no_v}_linux_amd64.tar.gz"

[[ "$source_epoch" =~ ^[0-9]+$ ]] || {
  echo "SOURCE_DATE_EPOCH must be an integer" >&2
  exit 2
}
test -f "$source_dir/LICENSE"
test -x "$binary"
mkdir -p "$out_dir"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
install -m 0755 "$binary" "$stage/caddy"
install -m 0644 "$source_dir/LICENSE" "$stage/LICENSE"
tar --sort=name --owner=0 --group=0 --numeric-owner \
  --mtime="@$source_epoch" --format=ustar -C "$stage" \
  -cf - LICENSE caddy | gzip -n >"$out_dir/$archive"
echo "$out_dir/$archive"
