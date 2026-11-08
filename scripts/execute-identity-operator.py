# © 2026 aiaiaiai · aiaiaiai.org

"""Runs on edge-prod-1; no deployment, migrations, shell evaluation or network."""

import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def require(condition, message):
    if not condition:
        raise ValueError(message)


def docker_command(container, binary, args):
    require(container["State"]["Running"], "identity is not running")
    require(container["State"].get("Health", {}).get("Status") == "healthy", "identity is not healthy")
    require(re.fullmatch(r"sha256:[0-9a-f]{64}", container["Image"]), "invalid live image id")
    require(container["Config"].get("User") == "identity", "unexpected identity runtime user")
    env = dict(v.split("=", 1) for v in container["Config"]["Env"] if "=" in v)
    require(env.get("DATABASE_URL") == "sqlite:///data/identity.db", "unexpected production database")
    mounts = [m for m in container["Mounts"] if m["Destination"] == "/data"]
    require(len(mounts) == 1 and mounts[0].get("Type") == "volume"
            and mounts[0].get("Name") == "nilxone-identity-data", "unexpected production volume")
    read_only = args in [["list", "bonds"], ["list", "business-bonds"]]
    require(read_only or (len(args) == 3 and args[0] == "create-business")
            or (len(args) == 4 and args[0] == "add-member" and args[3] in {"member", "owner"}),
            "unsupported operator operation")
    mount = "type=volume,source=nilxone-identity-data,target=/data"
    if read_only:
        mount += ",readonly"
    return ["docker", "run", "--rm", "--pull", "never", "--network", "none",
            "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
            "--user", "identity", "--env", "DATABASE_URL=sqlite:///data/identity.db",
            "--mount", mount, "--mount", f"type=bind,source={binary},target=/operator,readonly",
            "--entrypoint", "/operator", container["Image"], *args]


def main():
    directory, encoded, digest = sys.argv[1:]
    require(re.fullmatch(r"/tmp/nilxone-operator\.[A-Za-z0-9]{10}", directory), "invalid temporary directory")
    binary = Path(directory) / "nilxone-identity-operator"
    require(binary.is_file() and not binary.is_symlink(), "missing operator binary")
    require(re.fullmatch(r"[0-9a-f]{64}", digest), "invalid tool digest")
    require(hashlib.sha256(binary.read_bytes()).hexdigest() == digest, "uploaded tool digest mismatch")
    request = json.loads(base64.b64decode(encoded, validate=True))
    require(set(request) == {"schema", "args"} and request["schema"] == 1, "unknown request schema")
    args = request["args"]
    require(isinstance(args, list) and all(isinstance(v, str) and 0 < len(v) <= 256 for v in args), "invalid arguments")
    container = json.loads(subprocess.check_output(["docker", "inspect", "nilxone-identity"], text=True))[0]
    command = docker_command(container, str(binary), args)
    output = subprocess.check_output(command, text=True)
    print(json.dumps({"image_id": container["Image"],
                      "image": container["Config"]["Image"],
                      "contract_label": (container["Config"].get("Labels") or {}).get("one.nilx.identity.contract"),
                      "volume": "nilxone-identity-data", "result": json.loads(output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
