#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: publish-caddy-dbby-release.sh [--verify-only]" >&2
}

verify_only=false
if (($#)); then
  if [[ "$#" -eq 1 && "$1" == --verify-only ]]; then
    verify_only=true
  else
    usage
    exit 2
  fi
fi

for name in GH_TOKEN GITHUB_REPOSITORY GITHUB_SHA RELEASE_TAG BINARY_VERSION \
  SOURCE_REPOSITORY SOURCE_TAG SOURCE_SHA CADDY_VERSION CADDY_SHA \
  IMAGE_REPOSITORY IMAGE_TAG PUBLISHED_IMAGE_DIGEST ARCHIVE; do
  if [[ -z "${!name:-}" ]]; then
    echo "missing required release environment variable: $name" >&2
    exit 1
  fi
done

release_api="/repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG"
expected_name="Outline Caddy $BINARY_VERSION (Dobby build)"
release_json=out/logs/release.json
mkdir -p out/logs

validate_release() {
  local path=$1 state=$2
  RELEASE_TAG="$RELEASE_TAG" \
  EXPECTED_NAME="$expected_name" \
  SOURCE_TAG="$SOURCE_TAG" \
  SOURCE_SHA="$SOURCE_SHA" \
  IMAGE_REPOSITORY="$IMAGE_REPOSITORY" \
  PUBLISHED_IMAGE_DIGEST="$PUBLISHED_IMAGE_DIGEST" \
  EXPECTED_DRAFT="$state" \
  python3 - "$path" <<'PY'
import json
import os
import sys
from pathlib import Path

release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected_draft = os.environ["EXPECTED_DRAFT"] == "draft"
checks = {
    "tag_name": os.environ["RELEASE_TAG"],
    "name": os.environ["EXPECTED_NAME"],
    "draft": expected_draft,
    "prerelease": True,
}
for key, expected in checks.items():
    if release.get(key) != expected:
        raise SystemExit(f"release field {key} is {release.get(key)!r}; expected {expected!r}")
# GitHub's release response omits make_latest. The workflow sends false on
# create/update and separately snapshots the existing /releases/latest tag.
body = release.get("body", "")
for required in (
    f"Source: https://github.com/{os.environ['SOURCE_REPOSITORY']}/tree/{os.environ['SOURCE_TAG']}",
    f"Source commit: {os.environ['SOURCE_SHA']}",
    f"Image: {os.environ['IMAGE_REPOSITORY']}@{os.environ['PUBLISHED_IMAGE_DIGEST']}",
):
    if required not in body:
        raise SystemExit(f"release notes are missing required identity: {required}")
if not release.get("id"):
    raise SystemExit("release API response has no release id")
PY
}

validate_build_info() {
  local path=$1
  EXPECTED_SOURCE_REPOSITORY="$SOURCE_REPOSITORY" \
  EXPECTED_SOURCE_TAG="$SOURCE_TAG" \
  EXPECTED_SOURCE_SHA="$SOURCE_SHA" \
  EXPECTED_RELEASE_TAG="$RELEASE_TAG" \
  EXPECTED_BINARY_VERSION="$BINARY_VERSION" \
  EXPECTED_CADDY_VERSION="$CADDY_VERSION" \
  EXPECTED_CADDY_SHA="$CADDY_SHA" \
  EXPECTED_IMAGE_REPOSITORY="$IMAGE_REPOSITORY" \
  EXPECTED_IMAGE_TAG="$IMAGE_TAG" \
  EXPECTED_IMAGE_DIGEST="$PUBLISHED_IMAGE_DIGEST" \
  EXPECTED_ARCHIVE="$ARCHIVE" \
  python3 - "$path" <<'PY'
import hashlib
import json
import os
import sys
from pathlib import Path

info = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "product": "outline-caddy",
    "channel": "caddy-dbby",
    "release_tag": os.environ["EXPECTED_RELEASE_TAG"],
    "version": os.environ["EXPECTED_BINARY_VERSION"],
}
for key, value in expected.items():
    if info.get(key) != value:
        raise SystemExit(f"build-info {key} does not match the pinned release")
if info.get("source", {}).get("repository") != os.environ["EXPECTED_SOURCE_REPOSITORY"]:
    raise SystemExit("build-info source repository differs")
if info.get("source", {}).get("ref") != os.environ["EXPECTED_SOURCE_TAG"]:
    raise SystemExit("build-info source tag differs")
if info.get("source", {}).get("commit") != os.environ["EXPECTED_SOURCE_SHA"]:
    raise SystemExit("build-info source SHA differs")
if info.get("caddy", {}).get("version") != os.environ["EXPECTED_CADDY_VERSION"]:
    raise SystemExit("build-info Caddy version differs")
if info.get("caddy", {}).get("commit") != os.environ["EXPECTED_CADDY_SHA"]:
    raise SystemExit("build-info Caddy SHA differs")
image = info.get("image", {})
for key, expected_value in (
    ("repository", os.environ["EXPECTED_IMAGE_REPOSITORY"]),
    ("tag", os.environ["EXPECTED_IMAGE_TAG"]),
    ("published_index_digest", os.environ["EXPECTED_IMAGE_DIGEST"]),
):
    if image.get(key) != expected_value:
        raise SystemExit(f"build-info image {key} does not match the immutable image")
def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()

if info.get("archive", {}).get("name") != os.environ["EXPECTED_ARCHIVE"]:
    raise SystemExit("build-info archive name differs from the pinned asset")
if info.get("binary", {}).get("sha256") != sha256("out/caddy"):
    raise SystemExit("build-info binary SHA-256 does not match the verified binary")
if info.get("archive", {}).get("sha256") != sha256(f"out/{os.environ['EXPECTED_ARCHIVE']}"):
    raise SystemExit("build-info archive SHA-256 does not match the verified archive")
current_path = Path("out/build-info.json")
candidate_path = Path(sys.argv[1])
if current_path.is_file() and candidate_path.resolve() != current_path.resolve():
    current = json.loads(current_path.read_text(encoding="utf-8"))
    for key in ("product", "channel", "release_tag", "version", "source", "upstream_base",
                "caddy", "toolchain", "modules", "wrapper", "build", "binary", "archive"):
        if info.get(key) != current.get(key):
            raise SystemExit(f"downloaded build-info identity differs from the current build at {key}")
PY
}

expected_assets=("$ARCHIVE" checksums.txt build-info.json)

validate_local_assets() {
  local expected_names actual_names
  for name in "$ARCHIVE" checksums.txt build-info.json; do
    [[ -f "out/$name" ]] || { echo "local release asset is missing: out/$name" >&2; return 1; }
  done
  validate_build_info out/build-info.json
  expected_names=$(printf '%s\n' "$ARCHIVE" build-info.json | LC_ALL=C sort)
  actual_names=$(python3 - out/checksums.txt <<'PY'
import re
import sys
from pathlib import Path

names = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    match = re.fullmatch(r"[0-9a-f]{64}  (.+)", line)
    if not match:
        raise SystemExit(f"malformed release checksum line: {line!r}")
    names.append(match.group(1))
if len(names) != len(set(names)):
    raise SystemExit("release checksum file contains duplicate asset names")
print("\n".join(sorted(names)))
PY
)
  [[ "$actual_names" == "$expected_names" ]] || {
    echo "local checksum file must cover exactly the archive and build-info.json" >&2
    return 1
  }
  (cd out && sha256sum --strict -c checksums.txt)
}

validate_local_assets

asset_names() {
  python3 - "$1" <<'PY'
import json
import sys
from pathlib import Path
release = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
for asset in release.get("assets", []):
    print(asset["name"])
PY
}

download_release_assets() {
  local dest=$1 names=$2
  mkdir -p "$dest"
  if [[ -n "$names" ]]; then
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --dir "$dest"
  fi
}

verify_download_dir() {
  local dir=$1 compare_current=$2
  for name in "${expected_assets[@]}"; do
    [[ -f "$dir/$name" ]] || { echo "release is missing asset $name" >&2; return 1; }
  done
  actual_names=$(find "$dir" -maxdepth 1 -type f -printf '%f\n' | LC_ALL=C sort)
  expected_names=$(printf '%s\n' "${expected_assets[@]}" | LC_ALL=C sort)
  [[ "$actual_names" == "$expected_names" ]] || {
    echo "downloaded release asset names differ from the expected set" >&2
    return 1
  }
  (cd "$dir" && sha256sum -c checksums.txt)
  if [[ "$compare_current" == true ]]; then
    cmp -s "out/$ARCHIVE" "$dir/$ARCHIVE" || {
      echo "published release archive differs from the verified build" >&2
      return 1
    }
    validate_build_info "$dir/build-info.json"
    if [[ -f out/build-info.json ]]; then
      validate_build_info out/build-info.json
    fi
  fi
}

verify_public_release() {
  local path=$1
  validate_release "$path" public
  mapfile -t names < <(asset_names "$path")
  local name
  for name in "${expected_assets[@]}"; do
    if [[ ! " ${names[*]} " =~ " $name " ]]; then
      echo "public release is missing expected asset $name" >&2
      return 1
    fi
  done
  if [[ "${#names[@]}" -ne "${#expected_assets[@]}" ]]; then
    echo "public release contains unexpected assets" >&2
    return 1
  fi
  local dest
  dest=$(mktemp -d "out/logs/public-release-assets.XXXXXX")
  download_release_assets "$dest" "${names[*]}"
  verify_download_dir "$dest" true
}

if [[ "$verify_only" == true ]]; then
  gh api "$release_api" >"$release_json"
  verify_public_release "$release_json"
  echo "public release assets and provenance verified: $RELEASE_TAG"
  exit 0
fi

python3 - <<'PY'
import json
import os
from pathlib import Path

version = os.environ["BINARY_VERSION"]
source_repo = os.environ["SOURCE_REPOSITORY"]
source_tag = os.environ["SOURCE_TAG"]
source_sha = os.environ["SOURCE_SHA"]
request = {
    "tag_name": os.environ["RELEASE_TAG"],
    "target_commitish": os.environ["GITHUB_SHA"],
    "name": f"Outline Caddy {version} (Dobby build)",
    "body": (
        "Pinned Outline Caddy prerelease build.\n\n"
        f"Source: https://github.com/{source_repo}/tree/{source_tag}\n"
        f"Source commit: {source_sha}\n"
        f"Caddy: {os.environ['CADDY_VERSION']} ({os.environ['CADDY_SHA']})\n"
        f"Image: {os.environ['IMAGE_REPOSITORY']}@{os.environ['PUBLISHED_IMAGE_DIGEST']}\n"
        "See build-info.json for locked modules, toolchain, and checksums."
    ),
    "draft": True,
    "prerelease": True,
    "make_latest": "false",
}
Path("out/release-create.json").write_text(
    json.dumps(request, separators=(",", ":")) + "\n", encoding="utf-8"
)
PY

exists=false
if gh api "$release_api" >"$release_json" 2>out/logs/release-lookup.err; then
  exists=true
else
  status=$?
  if ! grep -Eiq 'HTTP 404|Not Found' out/logs/release-lookup.err; then
    cat out/logs/release-lookup.err >&2
    exit "$status"
  fi
fi

if [[ "$exists" == false ]]; then
  gh api --method POST "/repos/$GITHUB_REPOSITORY/releases" \
    --input out/release-create.json >"$release_json"
fi

release_id=$(python3 - "$release_json" <<'PY'
import json
import sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["id"])
PY
)
is_draft=$(python3 - "$release_json" <<'PY'
import json
import sys
from pathlib import Path
print(str(json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))["draft"]).lower())
PY
)

if [[ "$is_draft" == false ]]; then
  verify_public_release "$release_json"
  echo "public release already exists and matches the immutable build; left unchanged"
  exit 0
fi

validate_release "$release_json" draft
mapfile -t existing_names < <(asset_names "$release_json")
for name in "${existing_names[@]}"; do
  if [[ ! " ${expected_assets[*]} " =~ " $name " ]]; then
    echo "draft contains unexpected release asset $name; refusing to alter it" >&2
    exit 1
  fi
done

existing_dir=out/logs/resumed-draft-assets
if [[ "${#existing_names[@]}" -gt 0 ]]; then
  download_release_assets "$existing_dir" "${existing_names[*]}"
  if [[ -f "$existing_dir/$ARCHIVE" ]] && ! cmp -s "out/$ARCHIVE" "$existing_dir/$ARCHIVE"; then
    echo "draft release archive differs from the verified build; refusing to overwrite" >&2
    exit 1
  fi
  if [[ -f "$existing_dir/build-info.json" ]]; then
    validate_build_info "$existing_dir/build-info.json"
    cp "$existing_dir/build-info.json" out/build-info.json
    (cd out && sha256sum "$ARCHIVE" build-info.json > checksums.txt)
  fi
  if [[ -f "$existing_dir/checksums.txt" ]] && ! cmp -s out/checksums.txt "$existing_dir/checksums.txt"; then
    echo "draft release checksums do not match its immutable assets; refusing to overwrite" >&2
    exit 1
  fi
fi

missing=()
for name in "${expected_assets[@]}"; do
  if [[ ! " ${existing_names[*]} " =~ " $name " ]]; then
    missing+=("out/$name")
  fi
done
if ((${#missing[@]})); then
  gh release upload "$RELEASE_TAG" "${missing[@]}" --repo "$GITHUB_REPOSITORY"
fi

gh api "$release_api" >"$release_json"
validate_release "$release_json" draft
mapfile -t uploaded_names < <(asset_names "$release_json")
if [[ "${#uploaded_names[@]}" -ne "${#expected_assets[@]}" ]]; then
  echo "draft release does not have the complete expected asset set" >&2
  exit 1
fi
draft_dir=out/logs/verified-draft-assets
download_release_assets "$draft_dir" "${uploaded_names[*]}"
verify_download_dir "$draft_dir" true

python3 - <<'PY'
import json
from pathlib import Path
Path("out/release-publish.json").write_text(
    json.dumps({"draft": False, "prerelease": True, "make_latest": "false"},
               separators=(",", ":")) + "\n",
    encoding="utf-8",
)
PY
gh api --method PATCH "/repos/$GITHUB_REPOSITORY/releases/$release_id" \
  --input out/release-publish.json >"$release_json"
verify_public_release "$release_json"
echo "release published only after draft assets were downloaded and verified: $RELEASE_TAG"
