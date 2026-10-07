# outline-tunnel-server

Docker build for `outline-ss-server`.

The image defaults to `-config=/etc/secrets/config.yml`. This makes the image
self-configuring on hosts such as Render that mount a runtime secret file at
that path but do not reliably apply a separately configured Docker command to
prebuilt images. Supplying arguments to `docker run` replaces the default
`CMD` while preserving the `/outline-ss-server` entrypoint.

## DobbyVPN fork builds

This repository publishes both official upstream builds and the server from
[DobbyVPN/outliner-tunnel-server-fork](https://github.com/DobbyVPN/outliner-tunnel-server-fork).
The fork's release tags end in `-dbby`, starting with `v1.9.2-dbby`.
Both its executable version and its published artifacts carry that suffix.

| Build | Native release tag | Container image tag | Moving image alias |
| --- | --- | --- | --- |
| Official upstream | `v1.9.2` | `v1.9.2` | `latest` |
| DobbyVPN fork | `v1.9.2-dbby` | `v1.9.2-dbby` | `latest-dbby` |

The fork is built from an exact tag in the source repository's `dbby` branch.
The binary workflow's `dbby` channel publishes Linux amd64 archives such as
`outline-ss-server_1.9.2-dbby_linux_x86_64.tar.gz`, along with checksums and
source provenance, to this repository's GitHub Releases. The dbby image
workflow builds Linux amd64, arm64, arm/v7, and arm/v6 images from that same
source tag and publishes them under `ghcr.io/dobbyvpn/outline-ss-server`.

The dbby binary schedule runs at 06:00 UTC and the image schedule at 06:30 UTC.
Both workflows can also be dispatched manually with an exact fork release tag.
An empty binary ref discovers all `vX.Y.Z-dbby` tags; an empty image ref selects
the newest one. Version tags and release
assets are immutable. The fork's `latest-dbby` image alias advances independently
of the official `latest` alias, and official stable remains the latest GitHub
Release.

For example:

```sh
docker pull ghcr.io/dobbyvpn/outline-ss-server:v1.9.2-dbby
```

The fork retains the `outline-ss-server` executable and existing configuration
identities. Its TLS certificate files are supplied by an external handler;
see the fork's [packet WebSocket and certificate documentation](https://github.com/DobbyVPN/outliner-tunnel-server-fork/blob/v1.9.2-dbby/docs/dobbyvpn-packet-websocket.md).

## Standalone binary releases

The native binary workflow publishes GitHub Releases alongside the container images. It currently targets Linux amd64 and emits an upstream-compatible archive, checksums.txt, and build-info.json.

Stable versions reuse the official OutlineFoundation/tunnel-server archive after verifying its published checksum. Prerelease and development versions are built in GitHub Actions from the exact upstream tag or commit, without changing upstream source. Source builds run upstream Go build/tests and check the binary version, architecture, and example web/TCP/UDP startup.

The release tag matches the upstream tag. Development tags use dev-YYMonDD-<12-character-commit>, based on the upstream commit's UTC date. The scheduled runs follow the image channels: stable at 03:00 UTC, development at 04:00 UTC, and prerelease at 05:00 UTC. Use the Native Outline binaries workflow's manual dispatch to select a channel or exact upstream ref.

Each release records the upstream and wrapper commits in build-info.json. Verify a download with:

    sha256sum --check checksums.txt

Published assets are never replaced: reruns validate an existing release and stop if its identity or checksums do not match. Only the current upstream stable release is marked as the repository's latest release. Creating a binary release does not build or publish a container image.

## Image channels

- `ghcr.io/dobbyvpn/outline-ss-server:latest` points to the latest stable
  upstream release. Version tags such as `:v1.9.2` are immutable.
- Upstream prerelease tags are built under the same names, for example
  `:v1.9.3-rc2`.
- The daily development build of upstream `OutlineFoundation/tunnel-server`
  `master` uses an immutable tag in the form
  `:dev-YYMonDD-<12-character-commit>`, using the commit's UTC date.

`latest` is the moving upstream tag and always refers to a stable upstream
release. The fork has its own `latest-dbby` alias. The development and prerelease
workflows publish named tags only. Publishing an image does not update running
servers.

## Outline Caddy packet WebSocket builds

The manually dispatched **Manually reviewed Outline Caddy build** workflow builds
the Outline Caddy packet-WebSocket plugin from the exact source tag and pinned
Caddy, Go, Outline server, and container-image revisions in
[`caddy-dbby.lock.json`](caddy-dbby.lock.json). The published Caddy binary and
image use the separate `v2.11.7-dbby` identity; this workflow does not replace
the Outline server image or deploy to a running host.

The workflow input `source_tag` must match the locked tag. `publish` defaults to
`false`: that run builds and verifies the amd64 binary, smoke-checks the four
supported image platforms, and uploads a review artifact with the archive,
checksums, build provenance, OCI image archive, and test logs. After reviewing
that artifact, dispatch the same locked source tag with `publish=true` to
publish the immutable GitHub prerelease `caddy-v2.11.7-dbby` and GHCR image
`ghcr.io/dobbyvpn/outline-caddy:v2.11.7-dbby` for Linux amd64, arm64, arm/v7,
and arm/v6. The release contains
`caddy_2.11.7-dbby_linux_amd64.tar.gz`, `checksums.txt`, and `build-info.json`.
GitHub receives `make_latest=false`; publication downloads and verifies the
release assets before moving only the `latest-dbby` image alias, then checks
that the official GitHub latest release and
`ghcr.io/dobbyvpn/outline-ss-server:latest` image did not change.
The workflow stops after release and image publication; it does not deploy or
restart a running service.

The locked build uses Go 1.26.8, Caddy v2.11.7, and the exact module and base
image revisions in the lock file. Local source regression review requires Go
1.26.8. The full workflow uses Docker Buildx v0.37.2 and QEMU for cross-platform
image checks; its runner also needs Python 3, Bash, OpenSSL, curl, readelf, GNU
tar/gzip, and sha256sum. Registry and GitHub credentials are only used by the
publish job.

Run the release-helper state-machine tests and shell syntax checks locally:

```sh
python3 -m unittest discover -s tests -v
for script in scripts/*.sh; do bash -n "$script"; done
actionlint .github/workflows/caddy-dbby.yml
```

The source regression command used by CI is run from the checked-out source
module:

```sh
cd source/outlinecaddy
GOWORK=off GOTOOLCHAIN=local bash ./scripts/review.sh
```

Use the manual workflow's `publish=false` dispatch for a review artifact, then
dispatch the same source tag with `publish=true` only after reviewing it.

To verify a downloaded binary archive, extract it and run:

```sh
sha256sum --check checksums.txt
./caddy version
```

To use the multi-platform image:

```sh
docker pull ghcr.io/dobbyvpn/outline-caddy:v2.11.7-dbby
```
