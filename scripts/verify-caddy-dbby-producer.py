#!/usr/bin/env python3
"""Verify the exact failed producer run, its successful preview job, and artifact."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def api(repository: str, endpoint: str) -> dict:
    raw = subprocess.check_output(
        ["gh", "api", f"/repos/{repository}/{endpoint}"], text=True
    )
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise SystemExit(f"GitHub API returned a non-object for {endpoint}")
    return value


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--recipe-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()

    lock = json.loads(args.lock.read_text(encoding="utf-8"))
    producer = lock["producer"]
    repository = producer["repository"]
    recipe_dir = args.recipe_dir
    if subprocess.check_output(
        ["git", "-C", str(recipe_dir), "rev-parse", "HEAD"], text=True
    ).strip() != producer["head_commit"]:
        raise SystemExit("producer recipe checkout is not the pinned producer commit")

    pinned_hashes = lock["producer_recipe_hashes"]
    files = {
        "lockfile_sha256": recipe_dir / "caddy-dbby.lock.json",
        "dockerfile_sha256": recipe_dir / "Dockerfile.caddy",
        "build_script_sha256": recipe_dir / "scripts/build-caddy-dbby.sh",
    }
    for key, path in files.items():
        if sha256(path) != pinned_hashes[key]:
            raise SystemExit(f"producer recipe file hash mismatch: {path.name}")

    source = lock["source"]
    image = lock["image"]
    recipe_lock = json.loads((recipe_dir / "caddy-dbby.lock.json").read_text(encoding="utf-8"))
    if recipe_lock["source"]["repository"] != source["repository"]:
        raise SystemExit("producer recipe source repository differs from recovery lock")
    if recipe_lock["source"]["tag"] != source["tag"]:
        raise SystemExit("producer recipe source tag differs from recovery lock")
    if recipe_lock["source"]["commit"] != source["commit"]:
        raise SystemExit("producer recipe source commit differs from recovery lock")
    if recipe_lock["release"]["image_repository"] != image["repository"]:
        raise SystemExit("producer recipe image repository differs from recovery lock")
    if recipe_lock["release"]["image_tag"] != image["tag"]:
        raise SystemExit("producer recipe image tag differs from recovery lock")

    run_id = producer["run_id"]
    run = api(repository, f"actions/runs/{run_id}")
    expected_run = {
        "id": producer["run_id"],
        "run_attempt": producer["run_attempt"],
        "workflow_id": producer["workflow_id"],
        "path": producer["workflow_path"],
        "event": producer["run_event"],
        "head_sha": producer["head_commit"],
        "status": "completed",
        "conclusion": producer["run_conclusion"],
    }
    for key, expected in expected_run.items():
        if run.get(key) != expected:
            raise SystemExit(f"producer run field {key} is {run.get(key)!r}; expected {expected!r}")

    jobs = api(repository, f"actions/runs/{run_id}/jobs?per_page=100")
    job_by_name = {job.get("name"): job for job in jobs.get("jobs", [])}
    verify_job = job_by_name.get(producer["verify_job_name"])
    publish_job = job_by_name.get(producer["publish_job_name"])
    if not verify_job or verify_job.get("status") != "completed" or verify_job.get("conclusion") != "success":
        raise SystemExit("original producer verification job did not succeed")
    if not publish_job or publish_job.get("status") != "completed" or publish_job.get("conclusion") != "failure":
        raise SystemExit("original producer publish job was not the expected failed job")

    artifacts = api(repository, f"actions/runs/{run_id}/artifacts?per_page=100")
    matches = [
        artifact for artifact in artifacts.get("artifacts", [])
        if artifact.get("id") == producer["artifact_id"]
        and artifact.get("name") == producer["artifact_name"]
        and artifact.get("expired") is False
        and artifact.get("digest") == producer["artifact_digest"]
    ]
    if len(matches) != 1:
        raise SystemExit("pinned producer artifact is missing, expired, or ambiguous")
    artifact_run = matches[0].get("workflow_run") or {}
    if artifact_run.get("id") != run_id or artifact_run.get("head_sha") != producer["head_commit"]:
        raise SystemExit("pinned artifact metadata does not match the producer run")

    args.output_dir.mkdir(parents=True, exist_ok=True)
    evidence = {
        "producer_run": {key: run.get(key) for key in expected_run},
        "verify_job": {"name": verify_job.get("name"), "conclusion": verify_job.get("conclusion")},
        "publish_job": {"name": publish_job.get("name"), "conclusion": publish_job.get("conclusion")},
        "artifact": {
            "id": matches[0]["id"],
            "name": matches[0]["name"],
            "expired": matches[0]["expired"],
            "digest": matches[0]["digest"],
            "workflow_run_id": artifact_run.get("id"),
            "head_sha": artifact_run.get("head_sha"),
        },
    }
    output = args.output_dir / "producer-run-verification.json"
    output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"verified_producer_run={run_id}#{producer['run_attempt']}@{producer['head_commit']}")
    print(f"verified_preview_artifact={matches[0]['id']}:{matches[0]['name']}")


if __name__ == "__main__":
    main()
