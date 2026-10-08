#!/usr/bin/env python3
"""Verify the exact VCS origins of the pinned Caddy and Outline Go modules."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


def load_json_stream(path: Path) -> list[dict]:
    raw = path.read_text(encoding="utf-8")
    decoder = json.JSONDecoder()
    values = []
    offset = 0
    while offset < len(raw):
        while offset < len(raw) and raw[offset].isspace():
            offset += 1
        if offset >= len(raw):
            break
        value, offset = decoder.raw_decode(raw, offset)
        if not isinstance(value, dict):
            raise SystemExit("go mod download returned a non-object JSON value")
        values.append(value)
    return values


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", required=True, type=Path)
    parser.add_argument("--lockfile", type=Path, default=Path("caddy-dbby.lock.json"))
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    lock = json.loads(args.lockfile.read_text(encoding="utf-8"))
    source = lock["source"]
    caddy = lock["caddy"]
    module_dir = args.source_dir.resolve() / "outlinecaddy"
    if not (module_dir / "go.mod").is_file():
        raise SystemExit(f"Outline Caddy module not found: {module_dir}")

    requested = [
        f"github.com/caddyserver/caddy/v2@{caddy['version']}",
        f"{source['outline_server_module']}@{source['outline_server_version']}",
    ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    output = subprocess.check_output(
        ["go", "mod", "download", "-json", *requested],
        cwd=module_dir,
        env={**os.environ, "GOWORK": "off", "GOTOOLCHAIN": "local"},
        text=True,
    )
    temp = args.output.with_suffix(args.output.suffix + ".download.json")
    temp.parent.mkdir(parents=True, exist_ok=True)
    temp.write_text(output, encoding="utf-8")
    records = load_json_stream(temp)
    temp.unlink()
    by_path = {record.get("Path"): record for record in records}

    expected = {
        "github.com/caddyserver/caddy/v2": {
            "version": caddy["version"],
            "origin": caddy["module_origin"],
            "commit": caddy["commit"],
            "ref": f"refs/tags/{caddy['version']}",
        },
        source["outline_server_module"]: {
            "version": source["outline_server_version"],
            "origin": source["outline_server_module_origin"],
            "commit": source["outline_server_commit"],
            # Go pseudo-versions identify the commit in the version and VCS hash;
            # this upstream module origin has no Ref field.
            "ref": None,
        },
    }
    verified = []
    for module_path, pins in expected.items():
        record = by_path.get(module_path)
        if not record:
            raise SystemExit(f"go mod download did not resolve {module_path}")
        if record.get("Version") != pins["version"]:
            raise SystemExit(
                f"{module_path} resolved as {record.get('Version')!r}; expected {pins['version']!r}"
            )
        origin = record.get("Origin") or {}
        actual = (origin.get("URL"), origin.get("Hash"), origin.get("Ref"))
        expected_origin = (pins["origin"], pins["commit"], pins["ref"])
        if actual != expected_origin:
            raise SystemExit(
                f"{module_path} VCS origin is {actual!r}; expected {expected_origin!r}"
            )
        verified.append(
            {
                "path": module_path,
                "version": pins["version"],
                "origin": pins["origin"],
                "commit": pins["commit"],
                "ref": expected_origin[2],
                "sum": record.get("Sum", ""),
                "go_mod_sum": record.get("GoModSum", ""),
            }
        )

    result = {"schema_version": 1, "verified_modules": verified}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    for module in verified:
        print(f"verified_module={module['path']}@{module['version']}#{module['commit']}")


if __name__ == "__main__":
    main()
