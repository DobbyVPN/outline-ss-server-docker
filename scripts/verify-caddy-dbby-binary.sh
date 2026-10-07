#!/usr/bin/env bash
set -euo pipefail

if (($# < 2 || $# > 3)); then
  echo "Usage: verify-caddy-dbby-binary.sh BINARY VERSION [UPSTREAM_VERSION]" >&2
  exit 2
fi

binary="$1"
expected_version="$2"
expected_upstream_version="${3:-v2.11.7}"
test -x "$binary"

actual_version="$("$binary" version)"
read -r version_token upstream_token checksum_token extra_token <<<"$actual_version"
if [[ "$version_token" != "$expected_version" || "$upstream_token" != "$expected_upstream_version" || ( -n "$checksum_token" && "$checksum_token" != h1:* ) || -n "$extra_token" ]]; then
  echo "binary reports $actual_version; expected tokens $expected_version $expected_upstream_version and optional h1 checksum" >&2
  exit 1
fi

if readelf -l "$binary" | grep -q 'INTERP'; then
  echo "Caddy binary has a dynamic ELF interpreter; expected a static binary" >&2
  exit 1
fi

modules="$("$binary" list-modules)"
for module in outline caddy.listeners.outline_packet_tls http.handlers.websocket2layer4; do
  if ! grep -Fxq "$module" <<<"$modules"; then
    echo "Caddy binary does not contain module $module" >&2
    exit 1
  fi
done

go_info="$(go version -m "$binary")"
grep -Eq '^[[:space:]]*dep[[:space:]]+github\.com/caddyserver/caddy/v2[[:space:]]+v2\.11\.7([[:space:]]|$)' <<<"$go_info"
grep -Eq '^[[:space:]]*dep[[:space:]]+golang\.getoutline\.org/tunnel-server[[:space:]]+v1\.9\.3-rc2([[:space:]]|$)' <<<"$go_info"
grep -Eq '^[[:space:]]*dep[[:space:]]+golang\.getoutline\.org/sdk[[:space:]]+v0\.0\.23([[:space:]]|$)' <<<"$go_info"
grep -Eq '^[[:space:]]*dep[[:space:]]+golang\.getoutline\.org/sdk/x[[:space:]]+v0\.2\.0([[:space:]]|$)' <<<"$go_info"

echo "static binary version, Caddy module, Outline modules, and plugin registrations verified"
