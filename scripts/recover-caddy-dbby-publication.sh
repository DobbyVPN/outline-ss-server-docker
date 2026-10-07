#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${GITHUB_REPOSITORY:-}" || -z "${GITHUB_SHA:-}" || -z "${GITHUB_RUN_ID:-}" || -z "${GITHUB_RUN_ATTEMPT:-}" || -z "${GH_TOKEN:-}" ]]; then
  echo "run this recovery from the pinned GitHub Actions workflow" >&2
  exit 2
fi

recovery_tools="$(cd "$(dirname "$0")/.." && pwd -P)"
producer_dir="$(cd "${PRODUCER_RECIPE_DIR:-producer-recipe}" && pwd -P)"
lock="$recovery_tools/caddy-dbby-recovery.lock.json"
out="$producer_dir/out"
evidence="$out/recovery"
logs="$evidence/logs"
mkdir -p "$logs"
exec > >(tee -a "$logs/recovery.log") 2>&1

mapfile -t pins < <(python3 - "$lock" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
producer = data["producer"]
source = data["source"]
artifacts = data["artifacts"]
image = data["image"]
latest = data["official_latest"]
values = [
    producer["repository"], producer["head_commit"], str(producer["run_id"]),
    str(producer["run_attempt"]), str(producer["artifact_id"]),
    producer["artifact_name"], producer["artifact_digest"],
    source["repository"], source["tag"], source["commit"],
    source["upstream_base_commit"],
    artifacts["binary_sha256"], artifacts["archive_name"],
    artifacts["archive_sha256"], artifacts["preview_oci_archive_sha256"],
    artifacts["preview_index_digest"],
    image["repository"], image["tag"], image["index_digest"], image["moving_tag"],
    latest["release_tag"], latest["image_reference"], latest["image_digest"],
]
for value in values:
    if "\n" in value or "\r" in value:
        raise SystemExit("newline in recovery lock value")
    print(value)
PY
)
if [[ "${#pins[@]}" -ne 23 ]]; then
  echo "recovery lock did not produce the expected pinned values" >&2
  exit 1
fi
PRODUCER_REPOSITORY=${pins[0]}
PRODUCER_SHA=${pins[1]}
PRODUCER_RUN_ID=${pins[2]}
PRODUCER_RUN_ATTEMPT=${pins[3]}
PRODUCER_ARTIFACT_ID=${pins[4]}
PRODUCER_ARTIFACT_NAME=${pins[5]}
PRODUCER_ARTIFACT_DIGEST=${pins[6]}
SOURCE_REPOSITORY=${pins[7]}
SOURCE_TAG=${pins[8]}
SOURCE_SHA=${pins[9]}
UPSTREAM_BASE_SHA=${pins[10]}
EXPECTED_BINARY_SHA=${pins[11]}
ARCHIVE=${pins[12]}
EXPECTED_ARCHIVE_SHA=${pins[13]}
EXPECTED_PREVIEW_OCI_SHA=${pins[14]}
PREVIEW_OCI_INDEX_DIGEST=${pins[15]}
IMAGE_REPOSITORY=${pins[16]}
IMAGE_TAG=${pins[17]}
PUBLISHED_IMAGE_DIGEST=${pins[18]}
MOVING_IMAGE_TAG=${pins[19]}
OFFICIAL_LATEST_RELEASE=${pins[20]}
OFFICIAL_LATEST_IMAGE_REFERENCE=${pins[21]}
OFFICIAL_LATEST_IMAGE_DIGEST=${pins[22]}

if [[ "$GITHUB_REPOSITORY" != "$PRODUCER_REPOSITORY" ]]; then
  echo "recovery must run from $PRODUCER_REPOSITORY" >&2
  exit 1
fi
if [[ ! "$PUBLISHED_IMAGE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ || ! "$PREVIEW_OCI_INDEX_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "recovery lock contains an invalid image digest" >&2
  exit 1
fi

read_recipe_value() {
  python3 - "$producer_dir/caddy-dbby.lock.json" "$1" <<'PY'
import json
import sys
from pathlib import Path

value = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

SOURCE_LOCK_REPOSITORY="$(read_recipe_value source.repository)"
SOURCE_LOCK_TAG="$(read_recipe_value source.tag)"
SOURCE_LOCK_SHA="$(read_recipe_value source.commit)"
UPSTREAM_BASE_REPOSITORY="$(read_recipe_value source.upstream_base_repository)"
OUTLINE_SERVER_MODULE="$(read_recipe_value source.outline_server_module)"
OUTLINE_SERVER_MODULE_ORIGIN="$(read_recipe_value source.outline_server_module_origin)"
OUTLINE_SERVER_VERSION="$(read_recipe_value source.outline_server_version)"
OUTLINE_SERVER_SHA="$(read_recipe_value source.outline_server_commit)"
CADDY_VERSION="$(read_recipe_value caddy.version)"
CADDY_SHA="$(read_recipe_value caddy.commit)"
CADDY_MODULE_ORIGIN="$(read_recipe_value caddy.module_origin)"
CADDY_RUNTIME_IMAGE="$(read_recipe_value caddy.runtime_image)"
GO_VERSION="$(read_recipe_value go.version)"
GO_BUILDER_IMAGE="$(read_recipe_value go.builder_image)"
BINARY_VERSION="$(read_recipe_value release.binary_version)"
RELEASE_TAG="$(read_recipe_value release.release_tag)"
LOCK_IMAGE_REPOSITORY="$(read_recipe_value release.image_repository)"
LOCK_IMAGE_TAG="$(read_recipe_value release.image_tag)"
MOVING_IMAGE_TAG_FROM_RECIPE="$(read_recipe_value release.moving_image_tag)"

if [[ "$SOURCE_REPOSITORY" != "$SOURCE_LOCK_REPOSITORY" || "$SOURCE_TAG" != "$SOURCE_LOCK_TAG" || "$SOURCE_SHA" != "$SOURCE_LOCK_SHA" || \
  "$IMAGE_REPOSITORY" != "$LOCK_IMAGE_REPOSITORY" || "$IMAGE_TAG" != "$LOCK_IMAGE_TAG" || \
  "$MOVING_IMAGE_TAG" != "$MOVING_IMAGE_TAG_FROM_RECIPE" || "$GO_VERSION" != 1.26.8 ]]; then
  echo "recovery lock and original producer recipe identities differ" >&2
  exit 1
fi

if [[ "$(git -C "$producer_dir" rev-parse HEAD)" != "$PRODUCER_SHA" ]]; then
  echo "producer recipe checkout is not the original failed run commit" >&2
  exit 1
fi
if [[ "$(git -C "$producer_dir/source" rev-parse HEAD)" != "$SOURCE_SHA" || \
  "$(git -C "$producer_dir/source" rev-parse "refs/tags/$SOURCE_TAG^{commit}")" != "$SOURCE_SHA" ]]; then
  echo "source tag does not resolve to the pinned source commit" >&2
  exit 1
fi
git -C "$producer_dir/source" cat-file -e "$UPSTREAM_BASE_SHA^{commit}"
git -C "$producer_dir/source" merge-base --is-ancestor "$UPSTREAM_BASE_SHA" "$SOURCE_SHA"
git -C "$producer_dir/source" diff --name-only "$UPSTREAM_BASE_SHA...$SOURCE_SHA" \
  | python3 -c 'import sys; paths=[line.rstrip("\n") for line in sys.stdin]; bad=[p for p in paths if not p.startswith("outlinecaddy/")]; print("source_changed_paths="+str(len(paths))); bad and sys.exit("changes escape outlinecaddy/: "+", ".join(bad)); not paths and sys.exit("source has no changes from pinned upstream base")'
test -z "$(git -C "$producer_dir/source" status --porcelain=v1 --untracked-files=all)"

archive_sha="$(sha256sum "$out/$ARCHIVE" | awk '{print $1}')"
binary_sha="$(sha256sum "$out/caddy" | awk '{print $1}')"
preview_oci_sha="$(sha256sum "$out/outline-caddy.oci.tar" | awk '{print $1}')"
if [[ "$archive_sha" != "$EXPECTED_ARCHIVE_SHA" || "$binary_sha" != "$EXPECTED_BINARY_SHA" || "$preview_oci_sha" != "$EXPECTED_PREVIEW_OCI_SHA" ]]; then
  echo "downloaded preview artifact hashes differ from the recovery lock" >&2
  exit 1
fi
(cd "$out" && sha256sum --strict -c checksums.txt)
python3 - "$out/checksums.txt" "$ARCHIVE" <<'PY'
import hashlib
import sys
from pathlib import Path

checksums = Path(sys.argv[1]).read_text(encoding="utf-8")
archive = sys.argv[2]
expected = []
for name in (archive, "build-info.json"):
    digest = hashlib.sha256((Path(sys.argv[1]).parent / name).read_bytes()).hexdigest()
    expected.append(f"{digest}  {name}")
if checksums != "\n".join(expected) + "\n":
    raise SystemExit("original preview checksums do not exactly cover the pinned archive and build-info")
PY
chmod 0755 "$out/caddy"
"$producer_dir/scripts/verify-caddy-dbby-binary.sh" "$out/caddy" "$BINARY_VERSION" "$CADDY_VERSION" \
  2>&1 | tee "$logs/verify-binary.log"

SOURCE_DATE_EPOCH="$(git -C "$producer_dir/source" show -s --format=%ct "$SOURCE_SHA")"
SOURCE_DATE="$(date -u -d "@$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
WRAPPER_REPOSITORY="$GITHUB_REPOSITORY"
WRAPPER_SHA="$PRODUCER_SHA"
OUTLINE_SDK_VERSION=v0.0.23
OUTLINE_SDK_X_VERSION=v0.2.0
BUILD_SCRIPT_PATH="$producer_dir/scripts/build-caddy-dbby.sh"
DOCKERFILE_PATH="$producer_dir/Dockerfile.caddy"
LOCKFILE_PATH="$producer_dir/caddy-dbby.lock.json"

for file in "$BUILD_SCRIPT_PATH" "$DOCKERFILE_PATH" "$LOCKFILE_PATH"; do
  test -f "$file"
done
python3 "$producer_dir/scripts/verify-caddy-dbby-module-origins.py" \
  --source-dir "$producer_dir/source" \
  --lockfile "$LOCKFILE_PATH" \
  --output "$logs/module-origins.json" \
  2>&1 | tee "$logs/module-origin-verification.log"
test -z "$(git -C "$producer_dir/source" status --porcelain=v1 --untracked-files=all)"

archive_extract="$(mktemp -d "$logs/archive-extract.XXXXXX")"
python3 - "$out/$ARCHIVE" <<'PY'
import sys
import tarfile

with tarfile.open(sys.argv[1], "r:gz") as archive:
    names = archive.getnames()
    if sorted(names) != ["LICENSE", "caddy"]:
        raise SystemExit(f"unexpected release archive contents: {names!r}")
    if any(not member.isfile() for member in archive.getmembers()):
        raise SystemExit("release archive contains a non-regular member")
PY
tar -xzf "$out/$ARCHIVE" -C "$archive_extract" --no-same-owner
cmp -s "$out/caddy" "$archive_extract/caddy" || {
  echo "original release archive binary differs from the pinned preview binary" >&2
  exit 1
}
cmp -s "$producer_dir/source/LICENSE" "$archive_extract/LICENSE" || {
  echo "original release archive license differs from the source tag" >&2
  exit 1
}
python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' "$archive_extract"

export SOURCE_REPOSITORY SOURCE_TAG SOURCE_SHA UPSTREAM_BASE_REPOSITORY UPSTREAM_BASE_SHA
export OUTLINE_SERVER_MODULE OUTLINE_SERVER_MODULE_ORIGIN OUTLINE_SERVER_VERSION OUTLINE_SERVER_SHA
export CADDY_VERSION CADDY_SHA CADDY_MODULE_ORIGIN CADDY_RUNTIME_IMAGE GO_VERSION GO_BUILDER_IMAGE
export BINARY_VERSION RELEASE_TAG IMAGE_REPOSITORY IMAGE_TAG WRAPPER_REPOSITORY WRAPPER_SHA
export OUTLINE_SDK_VERSION OUTLINE_SDK_X_VERSION BUILD_SCRIPT_PATH DOCKERFILE_PATH LOCKFILE_PATH
export SOURCE_DATE SOURCE_DATE_EPOCH
(
  cd "$producer_dir"
  python3 scripts/write-caddy-dbby-build-info.py \
    --binary out/caddy \
    --archive "out/$ARCHIVE" \
    --preview-oci-archive out/outline-caddy.oci.tar \
    --preview-image-digest "$PREVIEW_OCI_INDEX_DIGEST" \
    --output out/recovery/rebuilt-preview-build-info.json
)
cmp -s "$out/build-info.json" "$out/recovery/rebuilt-preview-build-info.json" || {
  echo "downloaded preview build-info does not reproduce from the pinned binary, recipe, and source" >&2
  exit 1
}
rm "$out/recovery/rebuilt-preview-build-info.json"

assert_official_latest() {
  local stage=$1
  mkdir -p "$logs"
  gh api "/repos/$GITHUB_REPOSITORY/releases/latest" >"$logs/official-latest-release-$stage.json"
  local release_tag
  release_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$logs/official-latest-release-$stage.json")"
  if [[ "$release_tag" != "$OFFICIAL_LATEST_RELEASE" ]]; then
    echo "official latest release is $release_tag; expected $OFFICIAL_LATEST_RELEASE" >&2
    return 1
  fi
  local image_digest
  image_digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$OFFICIAL_LATEST_IMAGE_REFERENCE")"
  if [[ "$image_digest" != "$OFFICIAL_LATEST_IMAGE_DIGEST" ]]; then
    echo "official latest server image is $image_digest; expected $OFFICIAL_LATEST_IMAGE_DIGEST" >&2
    return 1
  fi
  echo "official_latest_release_$stage=$release_tag"
  echo "official_latest_server_image_$stage=$image_digest"
}

resolve_release_tag_target() {
  local allow_missing=$1
  python3 - "$GITHUB_REPOSITORY" "$RELEASE_TAG" "$allow_missing" <<'PY'
import json
import re
import subprocess
import sys

repository, tag, allow_missing = sys.argv[1:]
ref = f"/repos/{repository}/git/ref/tags/{tag}"
result = subprocess.run(["gh", "api", ref], text=True, capture_output=True)
if result.returncode:
    if allow_missing == "yes" and re.search(r"HTTP 404|Not Found", result.stderr, re.I):
        print("absent")
        raise SystemExit(0)
    sys.stderr.write(result.stderr)
    raise SystemExit(result.returncode)
value = json.loads(result.stdout)
obj = value.get("object", {})
for _ in range(8):
    kind, sha = obj.get("type"), obj.get("sha")
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise SystemExit("release tag has an invalid Git object")
    if kind == "commit":
        print(sha)
        break
    if kind != "tag":
        raise SystemExit(f"release tag resolves to unsupported object type {kind!r}")
    obj = json.loads(subprocess.check_output(
        ["gh", "api", f"/repos/{repository}/git/tags/{sha}"], text=True
    )).get("object", {})
else:
    raise SystemExit("release tag has too many annotated tag indirections")
PY
}

assert_official_latest before
existing_tag_target="$(resolve_release_tag_target yes)"
if [[ "$existing_tag_target" != absent && "$existing_tag_target" != "$PRODUCER_SHA" ]]; then
  echo "release tag already points to $existing_tag_target; expected producer commit $PRODUCER_SHA" >&2
  exit 1
fi

immutable_tag_digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE_REPOSITORY:$IMAGE_TAG")"
if [[ "$immutable_tag_digest" != "$PUBLISHED_IMAGE_DIGEST" ]]; then
  echo "immutable version tag resolves to $immutable_tag_digest; expected $PUBLISHED_IMAGE_DIGEST" >&2
  exit 1
fi
docker buildx imagetools inspect --raw "$IMAGE_REPOSITORY:$IMAGE_TAG" >"$logs/immutable-version-tag-index.json"
python3 "$recovery_tools/scripts/verify-caddy-dbby-image-index.py" \
  --index "$logs/immutable-version-tag-index.json" \
  --expected-index-digest "$PUBLISHED_IMAGE_DIGEST" \
  --output "$logs/version-tag-platform-manifests.tsv" \
  2>&1 | tee "$logs/verify-version-tag-index.log"

remote_index="$logs/immutable-image-index.json"
docker buildx imagetools inspect --raw "$IMAGE_REPOSITORY@$PUBLISHED_IMAGE_DIGEST" >"$remote_index"
python3 "$recovery_tools/scripts/verify-caddy-dbby-image-index.py" \
  --index "$remote_index" \
  --expected-index-digest "$PUBLISHED_IMAGE_DIGEST" \
  --output "$logs/platform-manifests.tsv" \
  2>&1 | tee "$logs/verify-immutable-index.log"

amd64_image_ref=
while IFS=$'\t' read -r platform child_digest; do
  case "$platform" in
    linux/amd64) arch=amd64 ;;
    linux/arm64) arch=arm64 ;;
    linux/arm/v7) arch=armv7 ;;
    linux/arm/v6) arch=armv6 ;;
    *) echo "unexpected validated index platform $platform" >&2; exit 1 ;;
  esac
  child_ref="$IMAGE_REPOSITORY@$child_digest"
  docker pull --platform "$platform" "$child_ref" 2>&1 | tee "$logs/pull-$arch.log"
  revision="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.revision" }}' "$child_ref")"
  version="$(docker image inspect --format '{{ index .Config.Labels "org.opencontainers.image.version" }}' "$child_ref")"
  wrapper_revision="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.wrapper-revision" }}' "$child_ref")"
  caddy_version="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.caddy-version" }}' "$child_ref")"
  caddy_revision="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.caddy-revision" }}' "$child_ref")"
  server_version="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.outline-server-version" }}' "$child_ref")"
  server_revision="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.outline-server-revision" }}' "$child_ref")"
  go_version="$(docker image inspect --format '{{ index .Config.Labels "com.dobbyvpn.outline-caddy.go-version" }}' "$child_ref")"
  if [[ "$revision" != "$SOURCE_SHA" || "$version" != "$BINARY_VERSION" || \
    "$wrapper_revision" != "$PRODUCER_SHA" || "$caddy_version" != "$CADDY_VERSION" || \
    "$caddy_revision" != "$CADDY_SHA" || "$server_version" != "$OUTLINE_SERVER_VERSION" || \
    "$server_revision" != "$OUTLINE_SERVER_SHA" || "$go_version" != "$GO_VERSION" ]]; then
    echo "$platform image labels do not match the original producer/source/module pins" >&2
    exit 1
  fi
  CADDY_UPSTREAM_VERSION="$CADDY_VERSION" \
    "$producer_dir/scripts/verify-caddy-dbby-image.sh" "$child_ref" "$platform" "$BINARY_VERSION" \
    2>&1 | tee "$logs/verify-image-$arch.log"
  if [[ "$platform" == linux/amd64 ]]; then
    amd64_image_ref=$child_ref
  fi
done <"$logs/platform-manifests.tsv"
if [[ -z "$amd64_image_ref" ]]; then
  echo "immutable image index has no verified amd64 child" >&2
  exit 1
fi

container="$(docker create --platform linux/amd64 "$amd64_image_ref")"
cleanup_container() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup_container EXIT
docker cp "$container:/usr/bin/caddy" "$out/recovery/caddy-from-published-image"
docker rm "$container" >/dev/null
trap - EXIT
cmp -s "$out/caddy" "$out/recovery/caddy-from-published-image" || {
  echo "published amd64 image binary differs from the pinned preview binary" >&2
  exit 1
}
rm "$out/recovery/caddy-from-published-image"

(
  cd "$producer_dir"
  python3 scripts/write-caddy-dbby-build-info.py \
    --binary out/caddy \
    --archive "out/$ARCHIVE" \
    --preview-oci-archive out/outline-caddy.oci.tar \
    --preview-image-digest "$PREVIEW_OCI_INDEX_DIGEST" \
    --published-image-digest "$PUBLISHED_IMAGE_DIGEST" \
    --output out/build-info.json
)
python3 - "$out/build-info.json" "$GITHUB_REPOSITORY" "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" \
  "$PRODUCER_REPOSITORY" "$PRODUCER_SHA" "$PRODUCER_RUN_ID" "$PRODUCER_RUN_ATTEMPT" "$PRODUCER_ARTIFACT_ID" \
  "$PRODUCER_ARTIFACT_NAME" "$PRODUCER_ARTIFACT_DIGEST" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
info = json.loads(path.read_text(encoding="utf-8"))
(recovery_repo, recovery_sha, recovery_run, recovery_attempt,
 producer_repo, producer_sha, producer_run, producer_attempt,
 artifact_id, artifact_name, artifact_digest) = sys.argv[2:]
info["recovery"] = {
    "publisher": {
        "repository": recovery_repo,
        "commit": recovery_sha,
        "run_id": recovery_run,
        "run_attempt": int(recovery_attempt),
    },
    "producer": {
        "repository": producer_repo,
        "commit": producer_sha,
        "run_id": producer_run,
        "run_attempt": int(producer_attempt),
        "artifact_id": int(artifact_id),
        "artifact_name": artifact_name,
        "artifact_digest": artifact_digest,
    },
}
path.write_text(json.dumps(info, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
(cd "$out" && sha256sum "$ARCHIVE" build-info.json > checksums.txt)
export GH_TOKEN GITHUB_REPOSITORY RELEASE_TAG BINARY_VERSION SOURCE_REPOSITORY SOURCE_TAG SOURCE_SHA
export CADDY_VERSION CADDY_SHA IMAGE_REPOSITORY IMAGE_TAG PUBLISHED_IMAGE_DIGEST ARCHIVE

cd "$producer_dir"
GITHUB_SHA="$PRODUCER_SHA" ./scripts/publish-caddy-dbby-release.sh \
  2>&1 | tee "$logs/publish-release.log"
tag_target="$(resolve_release_tag_target no)"
if [[ "$tag_target" != "$PRODUCER_SHA" ]]; then
  echo "published release tag resolves to $tag_target; expected original producer commit $PRODUCER_SHA" >&2
  exit 1
fi
GITHUB_SHA="$PRODUCER_SHA" ./scripts/publish-caddy-dbby-release.sh --verify-only \
  2>&1 | tee "$logs/verify-public-release.log"

# The moving alias changes only after the immutable image, all child platforms,
# provenance, and public prerelease assets have passed verification.
pre_alias_version_digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE_REPOSITORY:$IMAGE_TAG")"
if [[ "$pre_alias_version_digest" != "$PUBLISHED_IMAGE_DIGEST" ]]; then
  echo "immutable version tag changed before alias update: $pre_alias_version_digest" >&2
  exit 1
fi
docker buildx imagetools create --tag "$IMAGE_REPOSITORY:$MOVING_IMAGE_TAG" \
  "$IMAGE_REPOSITORY@$PUBLISHED_IMAGE_DIGEST" 2>&1 | tee "$logs/move-latest-dbby.log"
alias_raw="$logs/latest-dbby-index.json"
docker buildx imagetools inspect --raw "$IMAGE_REPOSITORY:$MOVING_IMAGE_TAG" >"$alias_raw"
alias_digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE_REPOSITORY:$MOVING_IMAGE_TAG")"
if [[ "$alias_digest" != "$PUBLISHED_IMAGE_DIGEST" ]]; then
  echo "moving alias resolved to $alias_digest; expected immutable index $PUBLISHED_IMAGE_DIGEST" >&2
  exit 1
fi
python3 "$recovery_tools/scripts/verify-caddy-dbby-image-index.py" \
  --index "$alias_raw" \
  --expected-index-digest "$PUBLISHED_IMAGE_DIGEST" \
  --output "$logs/alias-platform-manifests.tsv" \
  2>&1 | tee "$logs/verify-moving-alias.log"
assert_official_latest after
final_version_tag_digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$IMAGE_REPOSITORY:$IMAGE_TAG")"
if [[ "$final_version_tag_digest" != "$PUBLISHED_IMAGE_DIGEST" ]]; then
  echo "immutable version tag changed during recovery: $final_version_tag_digest" >&2
  exit 1
fi

echo "recovered_release=$RELEASE_TAG"
echo "immutable_image=$IMAGE_REPOSITORY@$PUBLISHED_IMAGE_DIGEST"
echo "moving_alias=$IMAGE_REPOSITORY:$MOVING_IMAGE_TAG"
