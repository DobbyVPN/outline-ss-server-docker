from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
PUBLISH_HELPER = REPO / "scripts" / "publish-caddy-dbby-release.sh"

FAKE_GH = r'''#!/usr/bin/env python3
import json
import os
import shutil
import sys
from pathlib import Path

state = Path(os.environ["FAKE_GH_STATE"])
assets = state / "assets"
assets.mkdir(parents=True, exist_ok=True)
ops = state / "operations.log"
args = sys.argv[1:]

def log(*parts):
    with ops.open("a", encoding="utf-8") as output:
        output.write(" ".join(map(str, parts)) + "\n")

def read_release():
    path = state / "release.json"
    if not path.exists():
        return None
    return json.loads(path.read_text(encoding="utf-8"))

def save_release(release):
    (state / "release.json").write_text(
        json.dumps(release, sort_keys=True) + "\n", encoding="utf-8"
    )

def payload(argv):
    if "--input" not in argv:
        return {}
    return json.loads(Path(argv[argv.index("--input") + 1]).read_text(encoding="utf-8"))

if args and args[0] == "api":
    method = "GET"
    if "--method" in args:
        method = args[args.index("--method") + 1]
    route = next((part for part in args[1:] if part.startswith("/repos/")), "")
    if method == "GET":
        release = read_release()
        if release is None:
            print("HTTP 404: Not Found", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(release))
        log("api-get", route)
        sys.exit(0)
    if method == "POST":
        data = payload(args)
        release = {
            "id": 101,
            "tag_name": data["tag_name"],
            "name": data["name"],
            "body": data["body"],
            "draft": data["draft"],
            "prerelease": data["prerelease"],
            "assets": [],
        }
        # Match the real GitHub release response: it omits make_latest.
        save_release(release)
        print(json.dumps(release))
        log("api-post", route, "draft", release["draft"])
        sys.exit(0)
    if method == "PATCH":
        release = read_release()
        if release is None:
            print("HTTP 404: Not Found", file=sys.stderr)
            sys.exit(1)
        data = payload(args)
        release.update(data)
        release.pop("make_latest", None)
        save_release(release)
        print(json.dumps(release))
        log("api-patch", route, "draft", release["draft"])
        sys.exit(0)
    raise SystemExit(f"unsupported fake API method: {method}")

if len(args) >= 2 and args[0] == "release" and args[1] == "upload":
    tag = args[2]
    release = read_release()
    if release is None or not release["draft"]:
        raise SystemExit("fake gh permits uploads only to a draft release")
    files = []
    index = 3
    while index < len(args):
        if args[index] == "--repo":
            index += 2
        else:
            files.append(Path(args[index]))
            index += 1
    for file in files:
        name = file.name
        if any(asset["name"] == name for asset in release["assets"]):
            raise SystemExit(f"asset overwrite rejected: {name}")
        shutil.copyfile(file, assets / name)
        release["assets"].append({"name": name})
        log("upload", name)
    save_release(release)
    sys.exit(0)

if len(args) >= 2 and args[0] == "release" and args[1] == "download":
    tag = args[2]
    release = read_release()
    if release is None or release["tag_name"] != tag:
        raise SystemExit("fake release not found")
    dest = Path(args[args.index("--dir") + 1])
    dest.mkdir(parents=True, exist_ok=True)
    for asset in release["assets"]:
        target = dest / asset["name"]
        if target.exists():
            raise SystemExit(f"download would overwrite existing file: {target}")
        shutil.copyfile(assets / asset["name"], target)
    log("download", len(release["assets"]), str(dest))
    sys.exit(0)

raise SystemExit(f"unsupported fake gh command: {args!r}")
'''


class PublishReleaseHelperTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="outline-caddy-release-test-")
        self.root = Path(self.temp.name)
        self.out = self.root / "out"
        (self.out / "logs").mkdir(parents=True)
        self.state = self.root / "gh-state"
        self.state.mkdir()
        fake_bin = self.root / "bin"
        fake_bin.mkdir()
        gh = fake_bin / "gh"
        gh.write_text(FAKE_GH, encoding="utf-8")
        gh.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{fake_bin}{os.pathsep}{self.env['PATH']}",
                "FAKE_GH_STATE": str(self.state),
                "GH_TOKEN": "mock-token",
                "GITHUB_REPOSITORY": "DobbyVPN/dobby-platform",
                "GITHUB_SHA": "b" * 40,
                "RELEASE_TAG": "caddy-v2.11.7-dbby",
                "BINARY_VERSION": "v2.11.7-dbby",
                "SOURCE_REPOSITORY": "DobbyVPN/outliner-tunnel-server-fork",
                "SOURCE_TAG": "outlinecaddy/v0.0.2-dbby",
                "SOURCE_SHA": "a" * 40,
                "CADDY_VERSION": "v2.11.7",
                "CADDY_SHA": "c" * 40,
                "IMAGE_REPOSITORY": "ghcr.io/dobbyvpn/outline-caddy",
                "IMAGE_TAG": "v2.11.7-dbby",
                "PUBLISHED_IMAGE_DIGEST": "sha256:" + "d" * 64,
                "ARCHIVE": "caddy_2.11.7-dbby_linux_amd64.tar.gz",
            }
        )
        self._write_assets()

    def tearDown(self) -> None:
        self.temp.cleanup()

    @staticmethod
    def sha(path: Path) -> str:
        return hashlib.sha256(path.read_bytes()).hexdigest()

    def _write_assets(self) -> None:
        (self.out / "caddy").write_bytes(b"verified caddy binary\n")
        (self.out / self.env["ARCHIVE"]).write_bytes(b"verified archive bytes\n")
        info = {
            "product": "outline-caddy",
            "channel": "caddy-dbby",
            "release_tag": self.env["RELEASE_TAG"],
            "version": self.env["BINARY_VERSION"],
            "source": {
                "repository": self.env["SOURCE_REPOSITORY"],
                "ref": self.env["SOURCE_TAG"],
                "commit": self.env["SOURCE_SHA"],
            },
            "upstream_base": {"commit": "e" * 40},
            "caddy": {"version": self.env["CADDY_VERSION"], "commit": self.env["CADDY_SHA"]},
            "toolchain": {"go_version": "1.26.8"},
            "modules": [{"path": "example.org/module", "version": "v1.0.0"}],
            "wrapper": {"repository": "DobbyVPN/dobby-platform", "commit": "b" * 40},
            "build": {"flags": ["-trimpath"]},
            "binary": {"sha256": self.sha(self.out / "caddy")},
            "archive": {
                "name": self.env["ARCHIVE"],
                "sha256": self.sha(self.out / self.env["ARCHIVE"]),
            },
            "image": {
                "repository": self.env["IMAGE_REPOSITORY"],
                "tag": self.env["IMAGE_TAG"],
                "published_index_digest": self.env["PUBLISHED_IMAGE_DIGEST"],
            },
        }
        (self.out / "build-info.json").write_text(
            json.dumps(info, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        with (self.out / "checksums.txt").open("w", encoding="utf-8") as output:
            for name in (self.env["ARCHIVE"], "build-info.json"):
                output.write(f"{self.sha(self.out / name)}  {name}\n")

    def _run_helper(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(PUBLISH_HELPER), *args],
            cwd=self.root,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def _log(self) -> list[str]:
        path = self.state / "operations.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def _seed_draft(self, *, archive_bytes: bytes | None = None, include_build_info: bool = False) -> None:
        (self.state / "assets").mkdir(parents=True, exist_ok=True)
        body = (
            "Pinned Outline Caddy prerelease build.\n\n"
            f"Source: https://github.com/{self.env['SOURCE_REPOSITORY']}/tree/{self.env['SOURCE_TAG']}\n"
            f"Source commit: {self.env['SOURCE_SHA']}\n"
            f"Caddy: {self.env['CADDY_VERSION']} ({self.env['CADDY_SHA']})\n"
            f"Image: {self.env['IMAGE_REPOSITORY']}@{self.env['PUBLISHED_IMAGE_DIGEST']}\n"
            "See build-info.json for locked modules, toolchain, and checksums."
        )
        release = {
            "id": 101,
            "tag_name": self.env["RELEASE_TAG"],
            "name": "Outline Caddy v2.11.7-dbby (Dobby build)",
            "body": body,
            "draft": True,
            "prerelease": True,
            "assets": [],
        }
        archive = self.env["ARCHIVE"]
        if archive_bytes is not None:
            (self.state / "assets" / archive).write_bytes(archive_bytes)
            release["assets"].append({"name": archive})
        if include_build_info:
            name = "build-info.json"
            shutil.copyfile(self.out / name, self.state / "assets" / name)
            release["assets"].append({"name": name})
        (self.state / "release.json").write_text(json.dumps(release), encoding="utf-8")

    def test_new_draft_is_verified_published_and_public_rerun_is_read_only(self) -> None:
        first = self._run_helper()
        self.assertEqual(first.returncode, 0, first.stdout)
        release = json.loads((self.state / "release.json").read_text(encoding="utf-8"))
        self.assertFalse(release["draft"])
        self.assertEqual(
            {asset["name"] for asset in release["assets"]},
            {self.env["ARCHIVE"], "checksums.txt", "build-info.json"},
        )
        self.assertNotIn("make_latest", release)

        verify_only = self._run_helper("--verify-only")
        self.assertEqual(verify_only.returncode, 0, verify_only.stdout)
        rerun = self._run_helper()
        self.assertEqual(rerun.returncode, 0, rerun.stdout)
        operations = self._log()
        self.assertEqual(sum(line.startswith("upload ") for line in operations), 3)
        self.assertEqual(sum(line.startswith("api-patch ") for line in operations), 1)
        downloads = [line for line in operations if line.startswith("download ")]
        self.assertEqual(len(downloads), 4)
        self.assertEqual(len({line.rsplit(" ", 1)[1] for line in downloads}), 4)

    def test_partial_matching_draft_uploads_only_missing_assets(self) -> None:
        self._seed_draft(archive_bytes=(self.out / self.env["ARCHIVE"]).read_bytes())
        result = self._run_helper()
        self.assertEqual(result.returncode, 0, result.stdout)
        release = json.loads((self.state / "release.json").read_text(encoding="utf-8"))
        self.assertFalse(release["draft"])
        uploads = [line for line in self._log() if line.startswith("upload ")]
        self.assertEqual(len(uploads), 2)
        self.assertFalse(any(self.env["ARCHIVE"] in line for line in uploads))

    def test_mismatched_draft_archive_is_rejected_without_upload_or_publish(self) -> None:
        self._seed_draft(archive_bytes=b"different archive\n")
        result = self._run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("differs from the verified build", result.stdout)
        release = json.loads((self.state / "release.json").read_text(encoding="utf-8"))
        self.assertTrue(release["draft"])
        self.assertFalse(any(line.startswith("upload ") for line in self._log()))
        self.assertFalse(any(line.startswith("api-patch ") for line in self._log()))

    def test_stale_draft_build_info_hash_is_rejected(self) -> None:
        self._seed_draft(
            archive_bytes=(self.out / self.env["ARCHIVE"]).read_bytes(),
            include_build_info=True,
        )
        stale_path = self.state / "assets" / "build-info.json"
        stale = json.loads(stale_path.read_text(encoding="utf-8"))
        stale["binary"]["sha256"] = "0" * 64
        stale_path.write_text(json.dumps(stale), encoding="utf-8")
        result = self._run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("binary SHA-256 does not match", result.stdout)
        release = json.loads((self.state / "release.json").read_text(encoding="utf-8"))
        self.assertTrue(release["draft"])
        self.assertFalse(any(line.startswith("upload ") for line in self._log()))
        self.assertFalse(any(line.startswith("api-patch ") for line in self._log()))

    def test_invalid_local_checksum_fails_before_creating_release(self) -> None:
        (self.out / "checksums.txt").write_text("0" * 64 + "  caddy_2.11.7-dbby_linux_amd64.tar.gz\n", encoding="utf-8")
        result = self._run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("local checksum file must cover exactly", result.stdout)
        self.assertFalse((self.state / "release.json").exists())
        self.assertFalse(any(line.startswith("api-post ") for line in self._log()))


if __name__ == "__main__":
    unittest.main()
