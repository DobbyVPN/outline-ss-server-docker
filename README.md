# outline-ss-server-docker

Docker build for `outline-ss-server`.

The image defaults to `-config=/etc/secrets/config.yml`. This makes the image
self-configuring on hosts such as Render that mount a runtime secret file at
that path but do not reliably apply a separately configured Docker command to
prebuilt images. Supplying arguments to `docker run` replaces the default
`CMD` while preserving the `/outline-ss-server` entrypoint.

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

`latest` is the only moving tag and always refers to a stable release. The
development and prerelease workflows publish named tags only. Publishing an
image does not update running servers.
