# outline-ss-server-docker

Docker build for `outline-ss-server`.

The image defaults to `-config=/etc/secrets/config.yml`. This makes the image
self-configuring on hosts such as Render that mount a runtime secret file at
that path but do not reliably apply a separately configured Docker command to
prebuilt images. Supplying arguments to `docker run` replaces the default
`CMD` while preserving the `/outline-ss-server` entrypoint.

## Image channels

- `ghcr.io/dobbyvpn/outline-ss-server:latest` and `:vX.Y.Z` package the latest
  upstream release.
- `ghcr.io/dobbyvpn/outline-ss-server:dev-latest` tracks the upstream
  `OutlineFoundation/tunnel-server` `master` branch. The daily workflow tests
  and builds the exact upstream commit, and publishes an immutable tag in the
  form `dev-YYMonDD-<12-character-commit>`, using the commit's UTC date.

The stable and development tags are separate. Publishing a new development
image does not update running servers.
