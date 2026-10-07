#!/usr/bin/env python3
"""Validate the pinned multi-platform index and emit child manifest digests."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


EXPECTED_PLATFORMS = {
    "linux/amd64",
    "linux/arm64",
    "linux/arm/v7",
    "linux/arm/v6",
}
IMAGE_MANIFEST_TYPES = {
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
}


def platform_name(value: object) -> str:
    if not isinstance(value, dict):
        raise SystemExit("index descriptor has no platform object")
    os_name = value.get("os")
    architecture = value.get("architecture")
    variant = value.get("variant", "")
    if not isinstance(os_name, str) or not isinstance(architecture, str):
        raise SystemExit(f"index descriptor has an invalid platform: {value!r}")
    if not isinstance(variant, str):
        raise SystemExit(f"index descriptor has an invalid platform variant: {value!r}")
    suffix = f"/{variant}" if variant else ""
    return f"{os_name}/{architecture}{suffix}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--expected-index-digest", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    expected_digest = args.expected_index_digest
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", expected_digest):
        raise SystemExit(f"invalid expected index digest: {expected_digest!r}")
    raw = args.index.read_bytes()
    actual_digest = "sha256:" + hashlib.sha256(raw).hexdigest()
    if actual_digest != expected_digest:
        raise SystemExit(
            f"raw image index digest {actual_digest} differs from expected {expected_digest}"
        )

    index = json.loads(raw)
    if index.get("schemaVersion") != 2:
        raise SystemExit(f"image index schemaVersion is {index.get('schemaVersion')!r}; expected 2")
    descriptors = index.get("manifests")
    if not isinstance(descriptors, list):
        raise SystemExit("image index has no manifest descriptor list")

    platform_digests: dict[str, str] = {}
    for descriptor in descriptors:
        if not isinstance(descriptor, dict):
            raise SystemExit("image index contains a malformed descriptor")
        platform = platform_name(descriptor.get("platform"))
        digest = descriptor.get("digest", "")
        if platform not in EXPECTED_PLATFORMS:
            raise SystemExit(f"unexpected image index platform: {platform}")
        if platform in platform_digests:
            raise SystemExit(f"duplicate image index platform: {platform}")
        if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise SystemExit(f"invalid child manifest digest for {platform}: {digest!r}")
        if descriptor.get("mediaType") not in IMAGE_MANIFEST_TYPES:
            raise SystemExit(
                f"unsupported child media type for {platform}: {descriptor.get('mediaType')!r}"
            )
        platform_digests[platform] = digest

    if set(platform_digests) != EXPECTED_PLATFORMS:
        raise SystemExit(
            f"image index platforms are {sorted(platform_digests)!r}; "
            f"expected {sorted(EXPECTED_PLATFORMS)!r}"
        )
    if len(set(platform_digests.values())) != len(EXPECTED_PLATFORMS):
        raise SystemExit("image index reuses a child manifest digest across platforms")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(f"{platform}\t{platform_digests[platform]}\n" for platform in sorted(platform_digests)),
        encoding="utf-8",
    )
    print(f"verified_index={actual_digest}")
    for platform in sorted(platform_digests):
        print(f"verified_child={platform}\t{platform_digests[platform]}")


if __name__ == "__main__":
    main()
