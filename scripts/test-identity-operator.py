# © 2026 aiaiaiai · aiaiaiai.org

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock


def module(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name + ".py"))
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


request = module("identity-operator-request")
execute = module("execute-identity-operator")


class OperatorTests(unittest.TestCase):
    def run_record(self):
        return {"actor": {"id": 1}, "triggering_actor": {"id": 1},
                "head_repository": {"full_name": "nilx-one/core"},
                "path": ".github/workflows/identity-create-business.yml",
                "event": "workflow_dispatch", "head_branch": "master",
                "status": "completed", "conclusion": "success", "run_attempt": 1,
                "head_sha": "a" * 40}

    def container(self):
        return {"State": {"Running": True, "Health": {"Status": "healthy"}},
                "Image": "sha256:" + "a" * 64,
                "Config": {"User": "identity", "Env": ["DATABASE_URL=sqlite:///data/identity.db"]},
                "Mounts": [{"Destination": "/data", "Type": "volume", "Name": "nilxone-identity-data"}]}

    def test_only_trusted_successful_master_requests_are_accepted(self):
        valid = self.run_record()
        request.validate_run(valid, {1}, 1)
        for key, value in [("head_branch", "feature/evil"), ("event", "pull_request"),
                           ("conclusion", "failure"), ("run_attempt", 2),
                           ("path", ".github/workflows/rust.yml"),
                           ("head_repository", {"full_name": "attacker/core"}),
                           ("actor", {"id": 2}), ("triggering_actor", {"id": 2})]:
            record = copy.deepcopy(valid)
            record[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                request.validate_run(record, {1}, 1)
        with self.assertRaises(ValueError):
            request.validate_run(valid, {1}, 2)

    def test_oci_source_and_run_are_verified_before_extraction(self):
        record = self.run_record()
        digest = "sha256:" + "b" * 64
        labels = {"one.nilx.operator.run-id": "22", "org.opencontainers.image.revision": record["head_sha"]}
        responses = [json.dumps({"digest": digest}), json.dumps([{"Config": {"Labels": labels}}]), "c" * 64]
        with tempfile.TemporaryDirectory() as path, \
             mock.patch.object(request.subprocess, "check_output", side_effect=responses), \
             mock.patch.object(request.subprocess, "run") as run:
            pinned = request.download_bundle("22", record, Path(path) / "bundle")
            self.assertTrue(pinned.endswith(digest))
            verify = run.call_args_list[0].args[0]
            self.assertEqual(verify[:3], ["gh", "attestation", "verify"])
            self.assertIn("--deny-self-hosted-runners", verify)
            self.assertEqual(verify[verify.index("--source-digest") + 1], record["head_sha"])
            self.assertEqual(verify[verify.index("--source-ref") + 1], "refs/heads/master")
            self.assertEqual(run.call_args_list[1].args[0], ["docker", "pull", pinned])
            self.assertEqual(run.call_args_list[2].args[0][:2], ["docker", "cp"])
            self.assertEqual(run.call_args_list[3].args[0][:2], ["docker", "rm"])
        responses = [json.dumps({"digest": digest}), json.dumps([{"Config": {"Labels": {}}}])]
        with tempfile.TemporaryDirectory() as path, \
             mock.patch.object(request.subprocess, "check_output", side_effect=responses), \
             mock.patch.object(request.subprocess, "run") as run, self.assertRaises(ValueError):
            request.download_bundle("22", record, Path(path) / "bundle")

    def test_listing_workflow_cannot_carry_a_write_and_owner_is_required(self):
        workflow = ".github/workflows/identity-list-bonds.yml"
        request.validate_request({"schema": 1, "args": ["list", "bonds"]}, workflow)
        with self.assertRaises(ValueError):
            request.validate_request({"schema": 1, "args": ["create-business", "0xdtest", "0x1alice"]}, workflow)
        with self.assertRaises(ValueError):
            request.validate_request({"schema": 1, "args": ["create-business", "0xdtest"]},
                                     ".github/workflows/identity-create-business.yml")
        for args in [["freed", "0xdtest"], ["hire", "0xdtest", "0x1alice"],
                     ["add-member", "0xdtest", "0x1alice", "maintainer"]]:
            with self.assertRaises(ValueError):
                request.validate_request({"schema": 1, "args": args},
                                         ".github/workflows/identity-add-member.yml")

    def test_corrupt_or_extra_artifact_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as path:
            directory = Path(path)
            contents = {"nilxone-identity-operator": b"binary", "request.json": b'{}'}
            for name, content in contents.items():
                (directory / name).write_bytes(content)
            (directory / "SHA256SUMS").write_text("".join(
                f"{hashlib.sha256(value).hexdigest()}  {name}\n" for name, value in contents.items()))
            request.verify_bundle(directory)
            (directory / "request.json").write_text('{"tampered":true}')
            with self.assertRaises(ValueError):
                request.verify_bundle(directory)
            (directory / "request.json").write_bytes(contents["request.json"])
            (directory / "extra").write_text("unexpected")
            with self.assertRaises(ValueError):
                request.verify_bundle(directory)

    def test_runtime_must_match_actual_production_database_and_nonroot_user(self):
        valid = self.container()
        for mutate in [lambda c: c["State"].update(Running=False),
                       lambda c: c["State"]["Health"].update(Status="unhealthy"),
                       lambda c: c["Config"].update(User="root"),
                       lambda c: c["Config"].update(Env=["DATABASE_URL=sqlite:///tmp/identity.db"]),
                       lambda c: c["Mounts"][0].update(Name="test-data"),
                       lambda c: c["Mounts"][0].update(Type="bind")]:
            container = copy.deepcopy(valid)
            mutate(container)
            with self.assertRaises(ValueError):
                execute.docker_command(container, "/tmp/operator", ["list", "bonds"])

    def test_read_only_listing_and_no_shell_or_deployment(self):
        listing = execute.docker_command(self.container(), "/tmp/operator", ["list", "bonds"])
        self.assertIn("type=volume,source=nilxone-identity-data,target=/data,readonly", listing)
        owner = "0x1alice;not-a-shell-command"
        mutation = execute.docker_command(self.container(), "/tmp/operator",
                                         ["create-business", "0xdtest", owner])
        self.assertEqual(mutation[-1], owner)
        self.assertIn("type=volume,source=nilxone-identity-data,target=/data", mutation)
        self.assertNotIn("sh", mutation)
        self.assertNotIn("--privileged", mutation)
        self.assertIn("--read-only", mutation)
        self.assertEqual(mutation[mutation.index("--network") + 1], "none")
        self.assertEqual(mutation[mutation.index("--pull") + 1], "never")


if __name__ == "__main__":
    unittest.main()
