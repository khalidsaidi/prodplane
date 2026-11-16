"""Deployment operator checks with mocked AWS, Terraform and Helm commands.

Run: python3 -m unittest discover -s tests -v
"""

import collections
import itertools
import json
import os
from pathlib import Path
import pty
import re
import select
import shlex
import subprocess
import tempfile
import time
import unittest

import hcl2
from hcl2.utils import SerializationOptions
import yaml


ROOT = Path(__file__).resolve().parents[1]
HCL_OPTIONS = SerializationOptions(with_comments=False, strip_string_quotes=True)
MOCKS = r'''
terraform() {
  printf 'MOCK_TERRAFORM %s\n' "$1"
  if [[ "${FAIL_PLAN_COMPONENT:-}" == "${PWD##*/}" && "$1" == plan ]]; then return 43; fi
  if [[ "${FAIL_APPLY:-}" == 1 && "$1" == apply ]]; then return 42; fi
}
aws() { echo 'UNEXPECTED_AWS_CALL' >&2; return 90; }
curl() { return 0; }
kubectl() { echo 'UNEXPECTED_KUBECTL_CALL' >&2; return 90; }
export -f terraform aws curl kubectl
'''


def run_script(script, args, answers="", extra_env=None):
    env = dict(os.environ, **(extra_env or {}))
    result = subprocess.run(
        ["bash", "-c", MOCKS + 'bash "$@"', "mock-run", str(ROOT / script), *args],
        cwd=ROOT, env=env, input=answers, text=True, capture_output=True, timeout=10,
    )
    if "UNEXPECTED_" in result.stdout + result.stderr:
        raise AssertionError(result.stdout + result.stderr)
    return result


class DeploymentScripts(unittest.TestCase):
    def test_selectors_cannot_be_interpreted_as_commands_or_paths(self):
        marker = 'SELECTOR_EXECUTED'
        for kind in ('network', 'cluster', 'environment'):
            for field, value in [('region', 'us-east-1; printf SELECTOR_EXECUTED >&2 #'),
                                 ('cluster-env', '../prod'), ('region', 'us-east-1 --help')]:
                args = ['--cluster-env', 'non-prod', '--region', 'us-east-1', '--execute', '--auto-approve']
                if kind == 'environment':
                    args += ['--environments', 'dev']
                args[args.index('--' + field) + 1] = value
                result = run_script(f'aws/terraform/deploy_{kind}.sh', args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertNotIn(marker, result.stderr)
                self.assertNotIn('MOCK_TERRAFORM', result.stdout)
        for environment in ('../dev', 'dev; printf SELECTOR_EXECUTED >&2 #', 'dev,,demo'):
            result = run_script('aws/terraform/deploy_environment.sh', [
                '--cluster-env', 'non-prod', '--region', 'us-east-1', '--environments', environment,
                '--start-codebuilds',
            ])
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('MOCK_TERRAFORM', result.stdout)

    def test_suggested_commands_reproduce_the_preview(self):
        for kind in ("network", "cluster", "environment"):
            script = f"aws/terraform/deploy_{kind}.sh"
            components = (None, "eks") if kind == "cluster" else (
                (None, "app_deploy") if kind == "environment" else (None,))
            environments = ("dev", "dev,demo") if kind == "environment" else (None,)
            for destroy, component, envs in itertools.product((False, True), components, environments):
                with self.subTest(kind=kind, destroy=destroy, component=component, envs=envs):
                    args = ["--cluster-env", "non-prod", "--region", "us-east-1"]
                    if component:
                        args += ["--component", component]
                    if envs:
                        args += ["--environments", envs]
                    if destroy:
                        args += ["--destroy"]
                    result = run_script(script, args)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    if kind == "cluster" and component is None:
                        self.assertNotIn("CLUSTER INFRASTRUCTURE COMPONENT '", result.stdout)
                    suggestions = [shlex.split(line) for line in result.stdout.splitlines()
                                   if line.startswith(str(ROOT / script) + " ")]
                    self.assertEqual(len(suggestions), 3 if envs else 2)
                    for command in suggestions:
                        self.assertEqual("--destroy" in command, destroy)
                        self.assertEqual("--component" in command, bool(component))
                        if component:
                            self.assertEqual(command[command.index("--component") + 1], component)
                        if envs:
                            self.assertEqual(command[command.index("--environments") + 1], envs)
                        preview = command[:command.index(">")] if ">" in command else [
                            x for x in command if x not in ("--execute", "--dry-run")]
                        repeated = run_script(script, preview[1:])
                        self.assertEqual(repeated.returncode, 0, repeated.stderr)
                        commands = lambda text: [x for x in text.splitlines()
                                                 if x.startswith(("terraform ", "cd "))]
                        self.assertEqual(commands(result.stdout), commands(repeated.stdout))
                        for command_line in commands(result.stdout):
                            words = shlex.split(command_line)
                            if words[:1] == ["terraform"] and words[1] in ("plan", "apply", "destroy"):
                                self.assertIn("-var=aws_region=us-east-1", words)
                                self.assertIn("-var=cluster_environment=non-prod", words)
                        # Copied cd commands must work in sequence, not nest component paths.
                        current = ROOT / "aws/terraform"
                        for line in commands(result.stdout):
                            if line.startswith("cd "):
                                current = (current / shlex.split(line)[1]).resolve()
                                self.assertTrue(current.is_dir(), str(current))

    def test_build_mode_rejects_dry_run_and_destroy(self):
        for incompatible in ("--dry-run", "--destroy"):
            result = run_script("aws/terraform/deploy_environment.sh", [
                "--cluster-env", "non-prod", "--region", "us-east-1", "--environments", "dev",
                "--start-codebuilds", incompatible,
            ])
            self.assertEqual(result.returncode, 2)
            self.assertIn("cannot be combined", result.stderr)
            self.assertNotIn("MOCK_TERRAFORM", result.stdout)

    def test_manual_build_selection_uses_state_ownership(self):
        mocks = r'''
terraform() {
  case "$2" in
    init)
      [[ "${TEST_FAILURE:-}" != init ]] || return 7
      [[ "$*" == *"config/non-prod/$TEST_ENV/us-east-1/non-prod-$TEST_ENV-us-east-1-backend.hcl"* ]] || return 96
      ;;
    output)
      [[ "${TEST_FAILURE:-}" != output ]] || return 7
      [[ "$3 $4" == '-json codebuild_project_arns' ]] || return 96
      printf '%s\n' "$TEST_PROJECTS"
      ;;
    *) return 96 ;;
  esac
}
aws() {
  case "$1 $2" in
    'sts get-caller-identity') printf '%s\n' "$TEST_ACCOUNT" ;;
    'codebuild start-build')
      printf '%s\n' "$*" >> "$TEST_CALLS"
      [[ "${TEST_FAILURE:-}" != start ]] || return 7
      ;;
    *) echo UNEXPECTED_AWS_CALL >&2; return 97 ;;
  esac
}
export -f terraform aws
'''
        arn = "arn:aws:codebuild:us-east-1:111122223333:project/"
        cases = [
            ("dev", {"release": arn + "dev-release"}, "", "111122223333", True, ["dev-release"]),
            ("dev-tools", {"release": arn + "dev-tools-release"}, "", "111122223333", True, ["dev-tools-release"]),
            ("dev", {"release": arn + "dev-release"}, "", "444455556666", False, []),
            ("dev", {"release": arn.replace("us-east-1", "us-west-2") + "dev-release"}, "", "111122223333", False, []),
            ("dev", {"valid": arn + "dev-release", "invalid": "not-an-arn"}, "", "111122223333", False, []),
            ("dev", {}, "", "111122223333", False, []),
            ("dev", {"release": arn + "dev-release"}, "init", "111122223333", False, []),
            ("dev", {"release": arn + "dev-release"}, "output", "111122223333", False, []),
            ("dev", {"release": arn + "dev-release"}, "start", "111122223333", False, ["dev-release"]),
        ]
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "calls"
            for environment, projects, failure, account, success, expected in cases:
                with self.subTest(environment=environment, projects=projects, failure=failure, account=account):
                    log.write_text("")
                    result = subprocess.run(["bash", "-c", mocks + 'bash "$@"', "mock",
                                             str(ROOT / "aws/terraform/deploy_environment.sh"),
                                             "--cluster-env", "non-prod", "--region", "us-east-1",
                                             "--environments", environment, "--start-codebuilds"],
                                            input="0\ny\n", capture_output=True, text=True, timeout=10,
                                            env={**os.environ, "TEST_ENV": environment,
                                                 "TEST_PROJECTS": json.dumps(projects), "TEST_FAILURE": failure,
                                                 "TEST_ACCOUNT": account, "TEST_CALLS": str(log)})
                    self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
                    self.assertNotIn("UNEXPECTED_AWS_CALL", result.stderr)
                    commands = [shlex.split(line) for line in log.read_text().splitlines()]
                    self.assertEqual([cmd[cmd.index("--project-name") + 1] for cmd in commands], expected)

    def test_environment_approval_and_completion(self):
        base = ["--cluster-env", "prod", "--region", "us-east-1", "--environments", "prod",
                "--component", "app_deploy", "--execute"]
        for destroy, answer in itertools.product((False, True), ("approve", "reject", "eof")):
            approved = answer == "approve"
            text = ("destroy-prod-confirm\n" if destroy else "apply-prod\n") if approved else (
                "no\n" if answer == "reject" else "")
            with self.subTest(destroy=destroy, answer=answer):
                result = run_script("aws/terraform/deploy_environment.sh",
                                    base + (["--destroy"] if destroy else []), text)
                self.assertEqual(result.returncode, 0, result.stderr)
                verb = "destroy" if destroy else "apply"
                self.assertEqual(result.stdout.count(f"MOCK_TERRAFORM {verb}\n"), int(approved))
                expected = ("ENVIRONMENT RESOURCES DESTROYED" if destroy else
                            "ENVIRONMENT RESOURCES DEPLOYED") if approved else "ENVIRONMENT OPERATIONS SKIPPED"
                self.assertIn(expected, result.stdout)
                if not approved:
                    self.assertNotIn("ENVIRONMENT RESOURCES DEPLOYED", result.stdout)
                    self.assertNotIn("ENVIRONMENT RESOURCES DESTROYED", result.stdout)

    def test_environment_partial_empty_and_failed_runs(self):
        common = ["--cluster-env", "prod", "--region", "us-east-1", "--environments", "prod", "--execute"]
        partial = run_script("aws/terraform/deploy_environment.sh", common, "apply-prod\nno\nno\nno\n")
        self.assertIn("PARTIALLY COMPLETED", partial.stdout)
        self.assertIn("Completed: 1; skipped: 3", partial.stdout)
        empty = run_script("aws/terraform/deploy_environment.sh",
                           ["--cluster-env", "prod", "--region", "us-east-1",
                            "--environments", "not-configured", "--execute"])
        self.assertIn("NO ENVIRONMENT OPERATIONS EXECUTED", empty.stdout)
        mixed = run_script("aws/terraform/deploy_environment.sh",
                           ["--cluster-env", "non-prod", "--region", "us-east-1",
                            "--environments", "dev,not-configured", "--component", "app_deploy",
                            "--execute", "--auto-approve"])
        self.assertIn("PARTIALLY COMPLETED", mixed.stdout)
        self.assertIn("Unconfigured target: app_deploy/non-prod/not-configured/us-east-1", mixed.stdout)
        failed = run_script("aws/terraform/deploy_environment.sh", common + ["--component", "app_deploy"],
                            "apply-prod\n", {"FAIL_APPLY": "1"})
        self.assertNotEqual(failed.returncode, 0)
        self.assertNotIn("ENVIRONMENT RESOURCES DEPLOYED", failed.stdout)

    def test_destroy_preflight_failure_precedes_all_mutations(self):
        result = run_script("aws/terraform/deploy_environment.sh",
                            ["--cluster-env", "non-prod", "--region", "us-east-1",
                             "--environments", "dev", "--destroy", "--execute", "--auto-approve"],
                            extra_env={"FAIL_PLAN_COMPONENT": "aws_deploy"})
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("Destroy preflight failed; no resources were destroyed", result.stdout)
        self.assertNotIn("MOCK_TERRAFORM destroy", result.stdout)

    def test_cluster_auto_approval_is_nonproduction_only(self):
        mocks = r'''terraform() { printf 'TF_ARGS %s\n' "$*"; }; export -f terraform; '''
        for cluster, destroy in itertools.product(("prod", "non-prod"), (False, True)):
            args = ["--cluster-env", cluster, "--region", "us-east-1", "--component", "security",
                    "--execute", "--auto-approve"] + (["--destroy"] if destroy else [])
            result = subprocess.run(["bash", "-c", mocks + 'bash "$@"', "mock",
                                     str(ROOT / "aws/terraform/deploy_cluster.sh"), *args],
                                    input="", capture_output=True, text=True, check=True)
            verb = "destroy" if destroy else "apply"
            commands = [line for line in result.stdout.splitlines() if line.startswith("TF_ARGS " + verb)]
            self.assertEqual(len(commands), 1)
            self.assertEqual("-auto-approve" in commands[0], cluster == "non-prod")
            self.assertIn("-var=aws_region=us-east-1", shlex.split(commands[0]))
            self.assertIn("-var=cluster_environment=" + cluster, shlex.split(commands[0]))

    def test_cluster_destroy_preflight_precedes_removing_addons(self):
        result = run_script("aws/terraform/deploy_cluster.sh",
                            ["--cluster-env", "non-prod", "--region", "us-east-1",
                             "--destroy", "--execute", "--auto-approve"],
                            extra_env={"FAIL_PLAN_COMPONENT": "storage"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Destroy preflight failed; no resources were destroyed", result.stdout)
        self.assertNotIn("MOCK_TERRAFORM destroy", result.stdout)

    def test_network_production_apply_requires_confirmation(self):
        for answer, auto in itertools.product(("apply-prod\n", "no\n", ""), (False, True)):
            args = ["--cluster-env", "prod", "--region", "us-east-1", "--execute"]
            if auto:
                args.append("--auto-approve")
            result = run_script("aws/terraform/deploy_network.sh", args, answer)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count("MOCK_TERRAFORM apply\n"), int(answer == "apply-prod\n"))
            if answer != "apply-prod\n":
                self.assertIn("NETWORK OPERATIONS SKIPPED", result.stdout)
                self.assertNotIn("NETWORK INFRASTRUCTURE DEPLOYED", result.stdout)

    def test_network_destroy_approval_and_nonprod_eof(self):
        common = ["--cluster-env", "prod", "--region", "us-east-1", "--destroy", "--execute"]
        for answer in ("destroy-prod-confirm\n", "no\n", ""):
            result = run_script("aws/terraform/deploy_network.sh", common, answer)
            approved = answer.startswith("destroy-prod-confirm")
            self.assertEqual(result.stdout.count("MOCK_TERRAFORM destroy\n"), int(approved))
            self.assertIn("NETWORK INFRASTRUCTURE DESTROYED" if approved else "NETWORK OPERATIONS SKIPPED",
                          result.stdout)
        for script in ("network", "environment"):
            args = ["--cluster-env", "non-prod", "--region", "us-east-1", "--execute"]
            if script == "environment":
                args += ["--environments", "dev", "--component", "app_deploy"]
            result = run_script(f"aws/terraform/deploy_{script}.sh", args)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("OPERATIONS SKIPPED", result.stdout)
            self.assertNotIn("MOCK_TERRAFORM apply", result.stdout)

    def test_production_terminal_waits_for_each_existing_confirmation(self):
        master, slave = pty.openpty()
        args = ["--cluster-env", "prod", "--region", "us-east-1", "--environments", "prod",
                "--component", "app_deploy", "--execute"]
        process = subprocess.Popen(
            ["bash", "-c", MOCKS + 'bash "$@"', "mock-run",
             str(ROOT / "aws/terraform/deploy_environment.sh"), *args],
            stdin=slave, stdout=slave, stderr=slave, cwd=ROOT,
        )
        os.close(slave)
        output = ""

        def wait_for(needle):
            nonlocal output
            deadline = time.monotonic() + 5
            while needle not in output:
                self.assertLess(time.monotonic(), deadline, output)
                if select.select([master], [], [], .1)[0]:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        self.fail(output)
                    self.assertTrue(chunk, output)
                    output += chunk.decode()

        try:
            wait_for("Type 'yes-prod' to confirm:")
            os.write(master, b"yes-prod\n")
            wait_for("Type 'apply-prod' to proceed:")
            self.assertIsNone(process.poll(), output)
            self.assertNotIn("MOCK_TERRAFORM apply", output)
            os.write(master, b"apply-prod\n")
            wait_for("ENVIRONMENT RESOURCES DEPLOYED")
            self.assertIn("MOCK_TERRAFORM apply", output)
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            os.close(master)

    def test_bastion_rule_uses_selected_state_and_reports_failure(self):
        mocks = MOCKS + r'''
curl() { printf '192.0.2.10\n'; }
terraform() {
  if [[ "$2" == output ]]; then
    [[ "${FAIL_STATE_OUTPUT:-}" != 1 ]] || return 7
    [[ "$3 $4" == '-raw bastion_sg_id' ]] || return 98
    echo sg-selected
  fi
}
aws() {
  printf '%s\n' "$*" >> "$TEST_CALLS"
  [[ "$1 $2" == 'ec2 authorize-security-group-ingress' ]] || return 90
  return 1
}
export -f curl terraform aws
'''
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "calls"
            for enabled, failure in itertools.product((False, True), (False, True)):
                log.write_text("")
                result = subprocess.run(
                    ["bash", "-c", mocks + 'bash "$@"', "mock-run",
                     str(ROOT / "aws/terraform/deploy_network.sh"), "--cluster-env", "non-prod",
                     "--region", "us-east-1", "--execute", "--auto-approve",
                     *(["--allow-current-ip"] if enabled else [])],
                    input="", text=True, capture_output=True, timeout=10,
                    env={**os.environ, "TEST_CALLS": str(log), "FAIL_STATE_OUTPUT": "1" if failure else "0"},
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                if not enabled:
                    self.assertEqual(log.read_text(), "")
                    self.assertNotIn("Adding inbound rule", result.stdout)
                elif failure:
                    self.assertIn("Could not read the selected bastion security group from state", result.stdout)
                    self.assertEqual(log.read_text(), "")
                else:
                    self.assertIn("Warning: Failed to add inbound rule", result.stdout)
                    calls = [shlex.split(line) for line in log.read_text().splitlines()]
                    self.assertEqual(len(calls), 1)
                    self.assertEqual(calls[0][calls[0].index("--group-id") + 1], "sg-selected")


class TerraformContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.roots = {}
        for scope in ("clusters", "environments"):
            for main in (ROOT / "aws/terraform" / scope).glob("*/main.tf"):
                blocks = collections.defaultdict(list)
                for path in main.parent.glob("*.tf"):
                    for key, value in hcl2.loads(path.read_text(), serialization_options=HCL_OPTIONS).items():
                        if isinstance(value, list):
                            blocks[key].extend(value)
                cls.roots[f"{scope}/{main.parent.name}"] = blocks

    def test_resources_have_explicit_region_configuration(self):
        for name, blocks in self.roots.items():
            with self.subTest(root=name):
                providers = {"aws" + ("." + b["aws"]["alias"] if "alias" in b["aws"] else ""): b["aws"]
                             for b in blocks["provider"] if "aws" in b}
                for category in ("resource", "data"):
                    for block in blocks[category]:
                        for kind, instances in block.items():
                            if not kind.startswith("aws_"):
                                continue
                            for body in instances.values():
                                provider = body.get("provider", "aws").removeprefix("${").removesuffix("}")
                                self.assertIn(provider, providers, (name, kind))
                                self.assertIn(providers[provider]["region"], (
                                    "${var.aws_region}", "${var.region_deploy_cluster}",
                                    "${local.peer_region}",
                                ))

    def test_remote_state_outputs_exist_at_the_producer(self):
        for name, blocks in self.roots.items():
            states = {label: body for block in blocks["data"] for kind, values in block.items()
                      if kind == "terraform_remote_state" for label, body in values.items()}
            for state, body in states.items():
                match = re.search(r"clusters/\$\{var.cluster_environment\}/([^/]+)/", body["config"]["key"])
                self.assertIsNotNone(match, (name, state))
                outputs = {key for block in self.roots["clusters/" + match[1]]["output"] for key in block}
                used = set(re.findall(r"data\.terraform_remote_state\." + state + r"\.outputs\.([A-Za-z_0-9]+)",
                                      json.dumps(blocks)))
                self.assertTrue(used <= outputs, (name, state, used - outputs))

    def test_backend_examples_match_inputs_and_do_not_share_state_keys(self):
        seen = set()
        for name in self.roots:
            for backend in (ROOT / "aws/terraform" / name).glob("config/**/*-backend.hcl.example"):
                inputs = backend.with_name(backend.name.replace("-backend.hcl.example", ".tfvars.example"))
                self.assertTrue(inputs.is_file(), str(backend.relative_to(ROOT)))
            for path in (ROOT / "aws/terraform" / name).glob("config/**/*.tfvars.example"):
                with self.subTest(file=str(path.relative_to(ROOT))):
                    values = hcl2.loads(path.read_text(), serialization_options=HCL_OPTIONS)
                    backend = path.with_name(path.name.replace(".tfvars.example", "-backend.hcl.example"))
                    settings = hcl2.loads(backend.read_text(), serialization_options=HCL_OPTIONS)
                    self.assertEqual(settings["bucket"], values["state_bucket"])
                    self.assertEqual(settings["region"], values["state_region"])
                    self.assertTrue(settings["key"].startswith(values["state_key_prefix"]))
                    if name.startswith("environments/"):
                        self.assertEqual(settings["key"], values["state_key_prefix"] + name + "/" +
                                         values["cluster_environment"] + "/" + values["environment"] + "/terraform.tfstate")
                    destination = (settings["bucket"], settings["region"], settings["key"])
                    self.assertNotIn(destination, seen)
                    seen.add(destination)


if __name__ == "__main__":
    unittest.main()
