#!/usr/bin/env bash
set -euo pipefail

if (($# != 3)); then
  echo "Usage: verify-caddy-dbby-image.sh IMAGE PLATFORM VERSION" >&2
  exit 2
fi

image="$1"
platform="$2"
expected_version="$3"
expected_modules=(
  outline
  caddy.listeners.outline_packet_tls
  http.handlers.websocket2layer4
)

expected_upstream_version="${CADDY_UPSTREAM_VERSION:-v2.11.7}"
actual_version="$(docker run --rm --platform "$platform" --entrypoint /usr/bin/caddy "$image" version)"
read -r version_token upstream_token checksum_token extra_token <<<"$actual_version"
if [[ "$version_token" != "$expected_version" || "$upstream_token" != "$expected_upstream_version" || ( -n "$checksum_token" && "$checksum_token" != h1:* ) || -n "$extra_token" ]]; then
  echo "$platform image reports $actual_version; expected tokens $expected_version $expected_upstream_version and optional h1 checksum" >&2
  exit 1
fi

modules="$(docker run --rm --platform "$platform" --entrypoint /usr/bin/caddy "$image" list-modules)"
for module in "${expected_modules[@]}"; do
  if ! grep -Fxq "$module" <<<"$modules"; then
    echo "$platform image does not contain Caddy module $module" >&2
    exit 1
  fi
done

smoke_dir="$(mktemp -d)"
container_name="outline-caddy-smoke-${GITHUB_RUN_ID:-local}-$$"
cleanup() {
  docker rm -f "$container_name" >/dev/null 2>&1 || true
  rm -rf "$smoke_dir"
}
trap cleanup EXIT

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
  -keyout "$smoke_dir/key.pem" \
  -out "$smoke_dir/cert.pem" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost" \
  >/dev/null 2>&1
chmod 0644 "$smoke_dir/key.pem" "$smoke_dir/cert.pem"
mkdir -p "$smoke_dir/www"
printf ok >"$smoke_dir/www/healthz"
cat >"$smoke_dir/config.json" <<'JSON'
{
  "admin": {"disabled": true},
  "apps": {
    "tls": {
      "certificates": {
        "load_files": [
          {"certificate": "/smoke/cert.pem", "key": "/smoke/key.pem"}
        ]
      }
    },
    "http": {
      "servers": {
        "smoke": {
          "listen": [":8443"],
          "protocols": ["h1"],
          "logs": {},
          "listener_wrappers": [
            {"wrapper": "outline_packet_tls"},
            {"wrapper": "tls"}
          ],
          "tls_connection_policies": [{}],
          "routes": [
            {
              "match": [{"path": ["/healthz"]}],
              "handle": [{"handler": "file_server", "root": "/smoke/www"}]
            }
          ]
        }
      }
    }
  }
}
JSON
chmod 0644 "$smoke_dir/config.json"

docker run --detach --name "$container_name" \
  --platform "$platform" \
  --publish 127.0.0.1::8443 \
  --mount "type=bind,src=$smoke_dir,dst=/smoke,readonly" \
  "$image" run --config /smoke/config.json >/dev/null

published_port="$(docker port "$container_name" 8443/tcp | sed 's/.*://')"
if [[ ! "$published_port" =~ ^[0-9]+$ ]]; then
  echo "could not determine published smoke port for $platform" >&2
  docker logs "$container_name" >&2 || true
  exit 1
fi

response=""
for attempt in $(seq 1 30); do
  if response="$(curl --fail --silent --show-error --max-time 4 \
    --cacert "$smoke_dir/cert.pem" \
    --resolve "localhost:$published_port:127.0.0.1" \
    "https://localhost:$published_port/healthz" 2>/dev/null)"; then
    break
  fi
  if ! docker inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null | grep -Fxq true; then
    docker logs "$container_name" >&2 || true
    echo "$platform Caddy container exited during HTTPS startup" >&2
    exit 1
  fi
  sleep 1
done
if [[ "$response" != ok ]]; then
  docker logs "$container_name" >&2 || true
  echo "$platform HTTPS smoke returned ${response@Q}; expected 'ok'" >&2
  exit 1
fi

echo "$platform version, module registration, file-server HTTPS, and packet TLS wrapper smoke passed"
