# © 2026 aiaiaiai · aiaiaiai.org

"""Verify a Core workflow request before a separate infra operator execution."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

REPOSITORY = "nilx-one/core"
WORKFLOWS = {
    ".github/workflows/identity-list-bonds.yml",
    ".github/workflows/identity-create-business.yml",
    ".github/workflows/identity-add-member.yml",
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def github(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def download_bundle(run_id, run, directory):
    image = "ghcr.io/nilx-one/core-identity-operator"
    manifest = json.loads(subprocess.check_output([
        "docker", "buildx", "imagetools", "inspect", f"{image}:request-{run_id}-1",
        "--format", "{{json .Manifest}}"], text=True))
    digest = manifest.get("digest", "")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", digest), "invalid request image digest")
    pinned = f"{image}@{digest}"
    subprocess.run(["gh", "attestation", "verify", f"oci://{pinned}",
                    "--repo", REPOSITORY,
                    "--signer-workflow", f"{REPOSITORY}/.github/workflows/identity-operator.yml",
                    "--source-ref", "refs/heads/master", "--source-digest", run["head_sha"],
                    "--deny-self-hosted-runners"], check=True)
    subprocess.run(["docker", "pull", pinned], check=True)
    inspected = json.loads(subprocess.check_output(["docker", "image", "inspect", pinned], text=True))[0]
    labels = inspected["Config"].get("Labels") or {}
    require(labels.get("one.nilx.operator.run-id") == str(run_id), "request image is from another run")
    require(labels.get("org.opencontainers.image.revision") == run["head_sha"], "request image source mismatch")
    container = subprocess.check_output(["docker", "create", pinned, "/unused"], text=True).strip()
    require(re.fullmatch(r"[0-9a-f]{64}", container), "unexpected temporary container id")
    try:
        directory.mkdir()
        subprocess.run(["docker", "cp", f"{container}:/bundle/.", str(directory)], check=True)
    finally:
        subprocess.run(["docker", "rm", container], check=True)
    return pinned


def validate_run(run, allowed, caller):
    require(caller in allowed, "untrusted infra operator")
    require(run.get("actor", {}).get("id") in allowed, "untrusted request actor")
    require(run.get("triggering_actor", {}).get("id") in allowed, "untrusted triggering actor")
    require(run.get("head_repository", {}).get("full_name") == REPOSITORY, "wrong source repository")
    require(run.get("path") in WORKFLOWS, "wrong source workflow")
    require(run.get("event") == "workflow_dispatch", "not a manual request")
    require(run.get("head_branch") == "master", "request is not from master")
    require(run.get("status") == "completed" and run.get("conclusion") == "success", "request not successful")
    require(run.get("run_attempt") == 1, "prepare a fresh request instead of re-running")
    require(re.fullmatch(r"[0-9a-f]{40}", run.get("head_sha", "")), "invalid source SHA")


def validate_request(request, workflow):
    require(set(request) == {"schema", "args"} and request["schema"] == 1, "unknown request schema")
    args = request["args"]
    require(isinstance(args, list) and all(isinstance(v, str) and 0 < len(v) <= 256 for v in args), "invalid arguments")
    if workflow.endswith("identity-list-bonds.yml"):
        require(args in [["list", "bonds"], ["list", "business-bonds"]], "listing workflow cannot mutate")
    elif workflow.endswith("identity-create-business.yml"):
        require(len(args) == 3 and args[0] == "create-business", "creation requires business and owner")
    elif workflow.endswith("identity-add-member.yml"):
        require(len(args) == 4 and args[0] == "add-member" and args[3] in {"member", "owner"}, "invalid member operation")
    else:
        raise ValueError("unsupported workflow")
    # Rust performs the actual address validation, without opening a database.
    return args


def verify_bundle(directory):
    require({p.name for p in directory.iterdir()} == {"nilxone-identity-operator", "request.json", "SHA256SUMS"}, "unexpected artifact files")
    for path in directory.iterdir():
        require(path.is_file() and not path.is_symlink(), "artifact must contain regular files")
    require((directory / "request.json").stat().st_size <= 4096, "request too large")
    require((directory / "nilxone-identity-operator").stat().st_size <= 100 * 1024 * 1024, "binary too large")
    sums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (nilxone-identity-operator|request\.json)", line)
        require(match is not None, "invalid checksum manifest")
        require(match[2] not in sums, "duplicate checksum")
        sums[match[2]] = match[1]
    require(set(sums) == {"nilxone-identity-operator", "request.json"}, "missing checksum")
    for name, digest in sums.items():
        require(hashlib.sha256((directory / name).read_bytes()).hexdigest() == digest, "artifact checksum mismatch")
    return sums["nilxone-identity-operator"]


def main():
    run_id = sys.argv[1]
    require(re.fullmatch(r"[1-9][0-9]{0,19}", run_id), "invalid run id")
    allowed = {int(v.strip()) for v in os.environ["OPERATOR_ACTOR_IDS"].split(",")}
    run = github(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    validate_run(run, allowed, int(os.environ["CALLER_ACTOR_ID"]))
    comparison = github(f"repos/{REPOSITORY}/compare/{run['head_sha']}...master")
    require(comparison.get("status") in {"ahead", "identical"}, "source is not in master ancestry")
    directory = Path("operator-bundle")
    require(not directory.exists(), "artifact directory already exists")
    image = download_bundle(run_id, run, directory)
    digest = verify_bundle(directory)
    request = json.loads((directory / "request.json").read_text())
    args = validate_request(request, run["path"])
    binary = directory / "nilxone-identity-operator"
    binary.chmod(0o500)
    checked = json.loads(subprocess.check_output([str(binary.resolve()), "--validate", *args],
                        env={"PATH": os.defpath}, text=True))
    require(checked == request, "Rust request validation mismatch")
    Path("operator-provenance.json").write_text(json.dumps({
        "source_run": int(run_id), "source_sha": run["head_sha"], "tool_sha256": digest,
        "request_image": image,
        "source_actor_id": run["actor"]["id"], "execution_actor_id": int(os.environ["CALLER_ACTOR_ID"]),
    }))
    print(f"Verified Core request {run_id} at {run['head_sha']}; production has not been touched.")


if __name__ == "__main__":
    main()
