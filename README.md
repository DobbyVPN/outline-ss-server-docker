# outline-ss-server-docker

Docker build for `outline-ss-server`.

The image defaults to `-config=/etc/secrets/config.yml`. This makes the image
self-configuring on hosts such as Render that mount a runtime secret file at
that path but do not reliably apply a separately configured Docker command to
prebuilt images. Supplying arguments to `docker run` replaces the default
`CMD` while preserving the `/outline-ss-server` entrypoint.

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
