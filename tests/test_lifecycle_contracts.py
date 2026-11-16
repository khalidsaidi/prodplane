"""Bootstrap, teardown and failure-path contracts using local mocks."""

import json
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

import hcl2
from hcl2.utils import SerializationOptions
import yaml

from test_deployment_contracts import ROOT, run_script


OPTIONS = SerializationOptions(with_comments=False, strip_string_quotes=True, preserve_heredocs=False)


class BootstrapAndTeardown(unittest.TestCase):
    def test_cluster_configures_kubernetes_before_storage(self):
        mocks = r'''
terraform() {
  if [ "$1" = output ]; then echo fixture-cluster; return; fi
  if [ "$1" = apply ] || [ "$1" = destroy ]; then echo "OP $(basename "$PWD") $1"; fi
}
aws() { [ "$1 $2" = 'eks update-kubeconfig' ] || exit 91; echo KUBECONFIG_READY; }
kubectl() { [ "$1 $2" = 'get nodes' ] || exit 92; echo NODES_READY; }
export -f terraform aws kubectl
'''
        for destroy in (False, True):
            args = ["--cluster-env", "non-prod", "--region", "us-east-1", "--execute", "--auto-approve"]
            if destroy:
                args.append("--destroy")
            result = subprocess.run(["bash", "-c", mocks + 'bash "$@"', "mock",
                                     str(ROOT / "aws/terraform/deploy_cluster.sh"), *args],
                                    input="", text=True, capture_output=True, check=True)
            ops = [line.split()[1] for line in result.stdout.splitlines() if line.startswith("OP ")]
            expected = ["security", "eks", "storage", "eks_addons"]
            self.assertEqual(ops, expected[::-1] if destroy else expected)
            if not destroy:
                self.assertLess(result.stdout.index("KUBECONFIG_READY"), result.stdout.index("OP storage apply"))

    def test_environment_namespace_releases_consumers_before_storage_teardown(self):
        mocks = '''terraform() { if [ "$1" = destroy ]; then echo "DESTROY $(basename "$PWD")"; fi; }; export -f terraform; '''
        result = subprocess.run(["bash", "-c", mocks + 'bash "$@"', "mock",
                                 str(ROOT / "aws/terraform/deploy_environment.sh"), "--cluster-env", "non-prod",
                                 "--region", "us-east-1", "--environments", "dev", "--destroy", "--execute", "--auto-approve"],
                                input="", text=True, capture_output=True, check=True)
        order = [line.split()[1] for line in result.stdout.splitlines() if line.startswith("DESTROY ")]
        self.assertEqual(order, ["app_deploy", "aws_deploy", "eventbridge", "storage"])

    def test_bastion_generates_executable_mount_script_and_propagates_failure(self):
        source = (ROOT / "aws/terraform/clusters/network/bastion.tf").read_text()
        # Terraform's indented heredoc strips common leading whitespace. Avoid
        # treating a parser's escaped string representation as executable shell.
        body = re.search(r"user_data = <<-EOF\n(.*?)^\s+EOF", source, re.S | re.M)[1]
        script = textwrap.dedent(body)
        self.assertTrue(script.startswith("#!/bin/bash\n"))
        script = script.replace("${var.cluster_environment}", "fixture").replace("${var.aws_region}", "us-east-1")
        token = "fixture's $(touch UNEXPECTED_TOKEN_COMMAND)"
        script = script.replace("${base64encode(var.efs_creation_token)}", base64.b64encode(token.encode()).decode())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for path in ("usr/local/bin", "etc/systemd/system", "mnt"):
                (root / path).mkdir(parents=True, exist_ok=True)
            script = script.replace("/usr/local/bin", str(root / "usr/local/bin"))
            script = script.replace("/etc/systemd/system", str(root / "etc/systemd/system"))
            script = script.replace("/mnt/fixture-efs", str(root / "mnt/fixture-efs"))
            script = script.replace("/etc/fstab", str(root / "fstab"))
            prefix = 'apt-get() { :; }; systemctl() { printf "SYSTEMCTL %s\\n" "$*"; }; '
            result = subprocess.run(["bash", "-c", prefix + script], text=True, capture_output=True, check=True)
            self.assertIn("SYSTEMCTL start --no-block mount-efs", result.stdout)
            mount_script = root / "usr/local/bin/mount-efs.sh"
            self.assertTrue(mount_script.read_text().startswith("#!/bin/bash\n"))
            self.assertTrue(os.access(mount_script, os.X_OK))
            self.assertTrue((root / "etc/systemd/system/mount-efs.service").is_file())
            for failure in (True, False):
                mocks = 'aws() { printf "%s\\0" "$@" > "$CALLS_FILE"; echo fs-fixture; }; grep() { return 1; }; mount() { return ' + ("7" if failure else "0") + '; }; export -f aws grep mount; '
                result = subprocess.run(["bash", "-c", mocks + 'bash "$1"', "mock", str(mount_script)],
                                        cwd=root, env={**os.environ, "CALLS_FILE": str(root / "aws-args")}, text=True, capture_output=True)
                args = (root / "aws-args").read_bytes().decode().split("\0")
                self.assertIn("--creation-token=" + token, args)
                self.assertIn("FileSystems[0].FileSystemId", args)
                self.assertFalse((root / "UNEXPECTED_TOKEN_COMMAND").exists())
                self.assertEqual(result.returncode, 7 if failure else 0, result.stderr)
                self.assertEqual((root / "fstab").exists(), not failure)


class ExampleCompleteness(unittest.TestCase):
    def test_iam_attachments_have_one_owner(self):
        root = ROOT / "aws/terraform/clusters/security"
        owners = {}
        for path in root.glob("*.tf"):
            data = hcl2.loads(path.read_text(), serialization_options=OPTIONS)
            for block in data.get("resource", []):
                for name, body in block.get("aws_iam_role_policy_attachment", {}).items():
                    binding = (body["role"], body["policy_arn"])
                    self.assertNotIn(binding, owners, (name, owners.get(binding)))
                    owners[binding] = name

    def test_operator_can_select_every_environment_example(self):
        for example in (ROOT / "aws/terraform/environments").glob("*/config/**/*.tfvars.example"):
            values = hcl2.loads(example.read_text(), serialization_options=OPTIONS)
            component = example.relative_to(ROOT / "aws/terraform/environments").parts[0]
            result = run_script("aws/terraform/deploy_environment.sh", [
                "--cluster-env", values["cluster_environment"], "--region", values["aws_region"],
                "--environments", values["environment"], "--component", component,
            ])
            relative = str(example.relative_to(ROOT / "aws/terraform/environments" / component))
            with self.subTest(example=str(example.relative_to(ROOT))):
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("Unconfigured target", result.stdout)
                self.assertIn("-var-file=" + relative.removesuffix(".example"), result.stdout)

    def test_bastion_discovers_the_corresponding_shared_filesystem(self):
        root = ROOT / "aws/terraform/clusters"
        for network in (root / "network/config").glob("**/*.tfvars.example"):
            relative = network.relative_to(root / "network")
            network_values = hcl2.loads(network.read_text(), serialization_options=OPTIONS)
            storage_values = hcl2.loads((root / "storage" / relative).read_text(), serialization_options=OPTIONS)
            with self.subTest(network=str(network.relative_to(ROOT))):
                self.assertEqual(network_values["efs_creation_token"], storage_values["efs_creation_token"])

    def test_every_example_supplies_declared_required_inputs(self):
        for scope in ("clusters", "environments"):
            for main in (ROOT / "aws/terraform" / scope).glob("*/main.tf"):
                variables = {}
                for path in main.parent.glob("*.tf"):
                    for block in hcl2.loads(path.read_text(), serialization_options=OPTIONS).get("variable", []):
                        variables.update(block)
                required = {name for name, body in variables.items() if "default" not in body}
                for example in main.parent.glob("config/**/*.tfvars.example"):
                    with self.subTest(example=str(example.relative_to(ROOT))):
                        values = hcl2.loads(example.read_text(), serialization_options=OPTIONS)
                        self.assertFalse(required - values.keys())
                        self.assertFalse(values.keys() - variables.keys())



if __name__ == "__main__":
    unittest.main()
