#!/usr/bin/env python3
"""Write deterministic provenance for the pinned Outline Caddy release."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing required environment value: {name}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_build_info(binary: Path) -> list[dict[str, str]]:
    output = subprocess.check_output(["go", "version", "-m", str(binary)], text=True)
    modules: list[dict[str, str]] = []
    for line in output.splitlines():
        fields = line.split()
        if not fields or fields[0] != "dep":
            continue
        if len(fields) < 3:
            raise SystemExit(f"malformed dependency line in go version -m: {line}")
        entry = {"path": fields[1], "version": fields[2]}
        for index, field in enumerate(fields[3:], start=3):
            if field.startswith("h1:"):
                entry["sum"] = field
            elif field == "=>" and len(fields) >= index + 3:
                entry["replace_path"] = fields[index + 1]
                entry["replace_version"] = fields[index + 2]
        modules.append(entry)
    if not modules:
        raise SystemExit("go version -m returned no dependency records")
    return sorted(modules, key=lambda module: module["path"])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--preview-oci-archive", type=Path)
    parser.add_argument("--preview-image-digest", default="")
    parser.add_argument("--published-image-digest", default="")
    args = parser.parse_args()

    required_paths = [args.binary, args.archive]
    if args.preview_oci_archive:
        required_paths.append(args.preview_oci_archive)
    for path in required_paths:
        if not path.is_file():
            raise SystemExit(f"required build artifact does not exist: {path}")

    source_commit = required("SOURCE_SHA")
    upstream_base_commit = required("UPSTREAM_BASE_SHA")
    caddy_commit = required("CADDY_SHA")
    wrapper_commit = required("WRAPPER_SHA")
    source_date = required("SOURCE_DATE")
    caddy_version = required("CADDY_VERSION")
    go_version = required("GO_VERSION")
    binary_version = required("BINARY_VERSION")
    release_tag = required("RELEASE_TAG")
    image_repository = required("IMAGE_REPOSITORY")
    image_tag = required("IMAGE_TAG")

    for label, value in (
        ("source commit", source_commit),
        ("upstream base commit", upstream_base_commit),
        ("Caddy commit", caddy_commit),
        ("wrapper commit", wrapper_commit),
    ):
        if not re.fullmatch(r"[0-9a-f]{40}", value):
            raise SystemExit(f"{label} is not a full lowercase Git SHA: {value}")

    modules = parse_build_info(args.binary)
    module_versions = {module["path"]: module["version"] for module in modules}
    expected_modules = {
        "github.com/caddyserver/caddy/v2": caddy_version,
        required("OUTLINE_SERVER_MODULE"): required("OUTLINE_SERVER_VERSION"),
        "golang.getoutline.org/sdk": required("OUTLINE_SDK_VERSION"),
        "golang.getoutline.org/sdk/x": required("OUTLINE_SDK_X_VERSION"),
    }
    for module, version in expected_modules.items():
        if module_versions.get(module) != version:
            raise SystemExit(
                f"binary module {module} is {module_versions.get(module)!r}; expected {version!r}"
            )

    image_digest = args.published_image_digest.strip()
    if image_digest and not re.fullmatch(r"sha256:[0-9a-f]{64}", image_digest):
        raise SystemExit(f"invalid published image digest: {image_digest}")
    preview_digest = args.preview_image_digest.strip()
    if preview_digest and not re.fullmatch(r"sha256:[0-9a-f]{64}", preview_digest):
        raise SystemExit(f"invalid preview image digest: {preview_digest}")

    build_script = Path(required("BUILD_SCRIPT_PATH"))
    dockerfile = Path(required("DOCKERFILE_PATH"))
    lockfile = Path(required("LOCKFILE_PATH"))
    if not all(path.is_file() for path in (build_script, dockerfile, lockfile)):
        raise SystemExit("build script, Dockerfile, and recipe must exist for provenance")

    binary_sha = sha256(args.binary)
    archive_sha = sha256(args.archive)
    go_info = subprocess.check_output(["go", "version", "-m", str(args.binary)], text=True)
    go_line = go_info.splitlines()[0] if go_info.splitlines() else ""
    if not go_line.split() or go_line.split()[-1] != f"go{go_version}":
        raise SystemExit(f"binary was built with an unexpected Go version: {go_line}")

    result = {
        "schema_version": 1,
        "product": "outline-caddy",
        "channel": "caddy-dbby",
        "release_tag": release_tag,
        "version": binary_version,
        "source": {
            "repository": required("SOURCE_REPOSITORY"),
            "ref": required("SOURCE_TAG"),
            "commit": source_commit,
            "commit_date_utc": source_date,
        },
        "upstream_base": {
            "repository": required("UPSTREAM_BASE_REPOSITORY"),
            "commit": upstream_base_commit,
            "outline_server_module": required("OUTLINE_SERVER_MODULE"),
            "outline_server_module_origin": required("OUTLINE_SERVER_MODULE_ORIGIN"),
            "outline_server_version": required("OUTLINE_SERVER_VERSION"),
            "outline_server_commit": required("OUTLINE_SERVER_SHA"),
        },
        "caddy": {
            "version": caddy_version,
            "commit": caddy_commit,
            "module_origin": required("CADDY_MODULE_ORIGIN"),
            "runtime_image": required("CADDY_RUNTIME_IMAGE"),
        },
        "toolchain": {
            "go_version": go_version,
            "builder_image": required("GO_BUILDER_IMAGE"),
        },
        "modules": modules,
        "wrapper": {
            "repository": required("WRAPPER_REPOSITORY"),
            "commit": wrapper_commit,
            "recipe_sha256": sha256(lockfile),
            "dockerfile_sha256": sha256(dockerfile),
            "build_script_sha256": sha256(build_script),
        },
        "build": {
            "command": "go build ./cmd/caddy",
            "flags": [
                "CGO_ENABLED=0",
                "GOOS=linux",
                "GOARCH=amd64",
                "GOAMD64=v1",
                "GOWORK=off",
                "GOTOOLCHAIN=local",
                "-mod=readonly",
                "-trimpath",
                "-buildvcs=false",
                "-tags=nomysql",
                f"-ldflags=-s -w -buildid= -X github.com/caddyserver/caddy/v2.CustomVersion={binary_version}",
            ],
            "go_build_info": go_line,
        },
        "binary": {"name": "caddy", "sha256": binary_sha},
        "archive": {"name": args.archive.name, "sha256": archive_sha},
        "preview_oci_archive": (
            {"name": args.preview_oci_archive.name, "sha256": sha256(args.preview_oci_archive)}
            if args.preview_oci_archive
            else None
        ),
        "image": {
            "repository": image_repository,
            "tag": image_tag,
            "preview_oci_index_digest": preview_digest or None,
            "published_index_digest": image_digest or None,
            "reference": f"{image_repository}@{image_digest}" if image_digest else None,
        },
    }

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
