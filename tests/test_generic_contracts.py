"""Application-neutral pipeline and operator-input contracts; no cloud calls."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace

import yaml

ROOT = Path(__file__).resolve().parents[1]


def recipe(name):
    return yaml.safe_load((ROOT / 'deployment/buildspecs' / (name + '.yml')).read_text())


class GenericPipelines(unittest.TestCase):
    def test_published_artifact_can_feed_an_application_dockerfile(self):
        spec = recipe('build-image')
        commands = '\n'.join(spec['phases']['pre_build']['commands'])
        mock = 'aws() { if [[ "$1" == ecr ]]; then echo token; else printf "FETCH"; printf " <%s>" "$@"; printf "\\n"; fi; }; docker() { cat >/dev/null; }; '
        with tempfile.TemporaryDirectory() as directory:
            env = {'PATH': os.environ['PATH'], 'IMAGE_REPOSITORY': '111122223333.dkr.ecr.us-east-1.amazonaws.com/runtime', 'IMAGE_TAG': 'v1',
                   'ARTIFACT_REGION': 'us-west-2', 'ARTIFACT_DOMAIN': 'releases', 'ARTIFACT_REPOSITORY': 'packages',
                   'ARTIFACT_FORMAT': 'maven', 'APP_PACKAGE': 'custom-package', 'ARTIFACT_NAMESPACE': 'org.example.team',
                   'ARTIFACT_VERSION': '7.3', 'ARTIFACT_ASSET': 'custom-package.jar', 'ARTIFACT_OUTPUT': 'inputs/custom binary.jar'}
            result = subprocess.run(['bash', '-c', mock + commands], cwd=directory, env=env, text=True, capture_output=True, check=True)
            for value in ('<get-package-version-asset>', '<--package=custom-package>', '<--package-version=7.3>', '<--asset=custom-package.jar>', '<inputs/custom binary.jar>'):
                self.assertIn(value, result.stdout)
            self.assertTrue(Path(directory, 'inputs').is_dir())

    def test_image_recipe_uses_application_dockerfile_and_never_pushes_failed_build(self):
        spec = recipe('build-image')
        for succeeded in ('0', '1'):
            with self.subTest(succeeded=succeeded), tempfile.TemporaryDirectory() as directory:
                receipt = Path(directory, spec['artifacts']['base-directory'], 'image.json')
                receipt.parent.mkdir()
                receipt.write_text('{"image":"stale:previous-run"}')
                source_file = Path(directory, 'image.json')
                source_file.write_text('{"application":"input"}')
                mock = 'aws() { echo token; }; docker() { if [[ "$1" == login ]]; then cat >/dev/null; fi; printf "DOCKER"; printf " <%s>" "$@"; printf "\\n"; }; '
                commands = '\n'.join(c for phase in ('pre_build', 'build', 'post_build') for c in spec['phases'][phase]['commands'])
                env = {'PATH': os.environ['PATH'], 'IMAGE_REPOSITORY': '111122223333.dkr.ecr.us-east-1.amazonaws.com/custom',
                       'IMAGE_TAG': 'release-42', 'ARTIFACT_REGION': 'us-east-1', 'DOCKERFILE': 'containers/worker.Dockerfile',
                       'BUILD_CONTEXT': 'source with spaces', 'CODEBUILD_BUILD_SUCCEEDING': succeeded}
                result = subprocess.run(['bash', '-c', mock + commands], cwd=directory, env=env, text=True, capture_output=True)
                self.assertIn('<containers/worker.Dockerfile>', result.stdout)
                self.assertIn('<source with spaces>', result.stdout)
                self.assertEqual('DOCKER <push>' in result.stdout, succeeded == '1')
                self.assertEqual(result.returncode == 0, succeeded == '1')
                if succeeded == '1':
                    self.assertEqual(json.loads(receipt.read_text())['image'], env['IMAGE_REPOSITORY'] + ':release-42')
                else:
                    self.assertFalse(receipt.exists())
                self.assertEqual(json.loads(source_file.read_text()), {'application': 'input'})

    def test_invalid_build_inputs_cannot_leave_a_previous_receipt(self):
        spec = recipe('build-image')
        with tempfile.TemporaryDirectory() as directory:
            receipt = Path(directory, spec['artifacts']['base-directory'], 'image.json')
            receipt.parent.mkdir()
            receipt.write_text('{"image":"stale:previous-run"}')
            commands = '\n'.join(spec['phases']['pre_build']['commands'])
            result = subprocess.run(['bash', '-c', commands], cwd=directory,
                                    env={'PATH': os.environ['PATH']}, text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(receipt.exists())

    def test_deploy_recipe_preserves_caller_release_chart_values_and_tag(self):
        spec = recipe('deploy-helm')
        commands = '\n'.join(c for phase in ('pre_build', 'build') for c in spec['phases'][phase]['commands'])
        mock = 'aws() { printf "AWS"; printf " <%s>" "$@"; printf "\\n"; }; helm() { printf "HELM"; printf " <%s>" "$@"; printf "\\n"; }; '
        env = {'PATH': os.environ['PATH'], 'EKS_CLUSTER_NAME': 'custom-cluster', 'CLUSTER_REGION': 'us-west-2',
               'NAMESPACE': 'team-a', 'RELEASE_NAME': 'processor', 'HELM_CHART': './custom chart',
               'IMAGE_REPOSITORY': 'registry.example.com/custom', 'IMAGE_TAG': 'v12',
               'HELM_VALUES_FILE': 'config/team a.yaml', 'HELM_ATOMIC': 'true', 'EKS_KUBECTL_ROLE_ARN': 'arn:aws:iam::111122223333:role/deployer'}
        result = subprocess.run(['bash', '-c', mock + commands], env=env, text=True, capture_output=True, check=True)
        for value in ('<processor>', '<./custom chart>', '<--namespace=team-a>', '<--values=config/team a.yaml>', '<image.tag=v12>', '<--wait>', '<--atomic>'):
            self.assertIn(value, result.stdout)
        self.assertIn('<--role-arn=arn:aws:iam::111122223333:role/deployer>', result.stdout)
        self.assertIn('<--set-literal>', result.stdout)
        self.assertIn('<--> <processor> <./custom chart>', result.stdout)

    def test_image_login_is_limited_to_private_ecr_and_uses_registry_region(self):
        commands = '\n'.join(recipe('build-image')['phases']['pre_build']['commands'])
        cases = [
            ('111122223333.dkr.ecr.us-east-1.amazonaws.com/app', 'us-east-1'),
            ('111122223333.dkr.ecr-fips.us-gov-west-1.amazonaws.com/app', 'us-gov-west-1'),
            ('111122223333.dkr-ecr.eu-west-1.on.aws/app', 'eu-west-1'),
            ('111122223333.dkr.ecr.cn-north-1.amazonaws.com.cn/app', 'cn-north-1'),
            ('111122223333.dkr.ecr.eusc-de-east-1.amazonaws.eu/app', 'eusc-de-east-1'),
            ('registry.example.com/app', None),
            ('111122223333.dkr.ecr.us-east-1.amazonaws.com.attacker.example/app', None),
            ('111122223333.dkr.ecr.us-east-1.amazonaws.com', None),
        ]
        mock = 'aws() { printf "%s\\n" "$*" >> "$CALLS_FILE"; echo fixture-token; }; docker() { cat >/dev/null; }; '
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory, 'calls')
            for repository, expected_region in cases:
                log.write_text('')
                env = {'PATH': os.environ['PATH'], 'IMAGE_REPOSITORY': repository, 'IMAGE_TAG': 'v1',
                       'ARTIFACT_REGION': 'us-west-2', 'CALLS_FILE': str(log)}
                result = subprocess.run(['bash', '-c', mock + commands], cwd=directory, env=env, text=True, capture_output=True)
                with self.subTest(repository=repository):
                    self.assertEqual(result.returncode == 0, expected_region is not None, result.stderr)
                    if expected_region:
                        self.assertIn('--region=' + expected_region, log.read_text())
                    else:
                        self.assertEqual(log.read_text(), '')

    def test_buildspec_commands_have_valid_shell_syntax(self):
        for path in (ROOT / 'deployment/buildspecs').glob('*.yml'):
            spec = yaml.safe_load(path.read_text())
            for phase, body in spec['phases'].items():
                with self.subTest(recipe=path.name, phase=phase):
                    self.assertTrue(all(isinstance(c, str) for c in body['commands']))
                    result = subprocess.run(['bash', '-n'], input='\n'.join(body['commands']), text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)


class OperatorInputs(unittest.TestCase):
    def test_secret_helper_uses_caller_name_and_file_without_logging_values(self):
        mock = 'aws() { if [[ "$2" == describe-secret ]]; then return "$DESCRIBE_STATUS"; fi; printf "%s\\n" "$@"; }; export -f aws; bash "$@"'
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, 'credentials with spaces.json')
            path.write_text('{"custom_key":"not-for-logs"}')
            for status, operation in (('0', 'put-secret-value'), ('1', 'create-secret')):
                env = {'PATH': os.environ['PATH'], 'AWS_REGION': 'us-west-2', 'DESCRIBE_STATUS': status}
                result = subprocess.run(['bash', '-c', mock, 'mock', str(ROOT / 'aws/terraform/scripts/secret_creator.sh'), 'team-service', str(path)],
                                        env=env, text=True, capture_output=True, check=True)
                self.assertIn(operation, result.stdout)
                self.assertIn('team-service', result.stdout)
                self.assertIn('file://' + str(path), result.stdout)
                self.assertNotIn('not-for-logs', result.stdout + result.stderr)
                literal = subprocess.run(['bash', '-c', mock, 'mock', str(ROOT / 'aws/terraform/scripts/secret_creator.sh'), '--help', str(path)],
                                         env=env, text=True, capture_output=True, check=True)
                expected = '--secret-id=--help' if status == '0' else '--name=--help'
                self.assertIn(expected, literal.stdout.splitlines())

    def test_artifact_operations_use_only_supplied_coordinates_and_versions(self):
        cases = [('versions',), ('get', 'v3', 'custom.jar', 'file with spaces.jar'), ('get', '--help', '--asset', '--output'),
                 ('copy', 'releases', 'v3', 'v4'), ('copy', 'releases', 'v3', '--allow-overwrite'),
                 ('status', 'Archived', 'v3'), ('delete', 'v3', 'v4')]
        env = {'PATH': os.environ['PATH'], 'ARTIFACT_REGION': 'us-west-2', 'ARTIFACT_DOMAIN': 'team',
               'ARTIFACT_REPOSITORY': 'packages', 'ARTIFACT_FORMAT': 'maven', 'APP_PACKAGE': 'processor',
               'ARTIFACT_NAMESPACE': 'org.example.team', 'AWS_ACCOUNT_ID': '111122223333'}
        mock = 'aws() { printf "%s\\n" "$@" > "$TEST_ARGS"; printf "%s\\n" "$TEST_RESPONSE"; }; export -f aws; bash "$@"'
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory, 'args')
            env.update(TEST_ARGS=str(log), TEST_RESPONSE='{"successfulVersions":{"v3":{"status":"Published"}},"failedVersions":{}}')
            for case in cases:
                versions = case[2:] if case[0] in ('copy', 'status') else case[1:] if case[0] == 'delete' else ['v3']
                env['TEST_RESPONSE'] = json.dumps({'successfulVersions': {v: {'status': 'Published'} for v in versions}, 'failedVersions': {}})
                result = subprocess.run(['bash', '-c', mock, 'mock', str(ROOT / 'deployment/tools/artifacts.sh'), *case],
                                        env=env, text=True, capture_output=True, check=True)
                raw_args = log.read_text().splitlines()
                args = [part for arg in raw_args for part in (arg.split('=', 1) if arg.startswith('--') and '=' in arg else [arg])]
                if case[0:2] == ('get', '--help'):
                    self.assertIn('--package-version=--help', raw_args)
                    self.assertIn('--asset=--asset', raw_args)
                    self.assertEqual(raw_args[-1], './--output')
                for flag, value in (('--region', 'us-west-2'), ('--domain', 'team'), ('--package', 'processor'), ('--namespace', 'org.example.team')):
                    self.assertEqual(args[args.index(flag) + 1], value)
                if '--versions' in args:
                    self.assertEqual(json.loads(args[args.index('--versions') + 1]), list(case[2:] if case[0] in ('copy', 'status') else case[1:]))
                    self.assertNotIn('--allow-overwrite', args)
            result = subprocess.run(['bash', '-c', mock, 'mock', str(ROOT / 'deployment/tools/artifacts.sh'), 'delete'], env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('codeartifact', result.stdout)

    def test_artifact_batch_partial_success_is_not_reported_as_success(self):
        env = {'PATH': os.environ['PATH'], 'ARTIFACT_REGION': 'us-west-2', 'ARTIFACT_DOMAIN': 'team',
               'ARTIFACT_REPOSITORY': 'packages', 'ARTIFACT_FORMAT': 'maven', 'APP_PACKAGE': 'processor',
               'ARTIFACT_NAMESPACE': 'org.example.team'}
        response = {'successfulVersions': {'v4': {'status': 'Published'}},
                    'failedVersions': {'v3': {'errorCode': 'NOT_FOUND', 'errorMessage': 'No such version'}}}
        mock = 'aws() { printf "%s\\n" "$TEST_RESPONSE"; }; export -f aws; bash "$@"'
        for case in [('copy', 'destination', 'v3', 'v4'), ('status', 'Archived', 'v3', 'v4'), ('delete', 'v3', 'v4')]:
            result = subprocess.run(['bash', '-c', mock, 'mock', str(ROOT / 'deployment/tools/artifacts.sh'), *case],
                                    env={**env, 'TEST_RESPONSE': json.dumps(response)}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout), response)
            self.assertIn('did not report complete success', result.stderr)

    def test_hosted_zone_selection_does_not_guess_between_matching_zones(self):
        path = ROOT / 'aws/terraform/scripts/update_route53.py'
        spec = importlib.util.spec_from_file_location('route_target', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        public = {'Id': '/hostedzone/ZPUBLIC', 'Name': 'example.com.', 'Config': {'PrivateZone': False}}
        private = {'Id': '/hostedzone/ZPRIVATE', 'Name': 'example.com.', 'Config': {'PrivateZone': True}}
        other = {'Id': '/hostedzone/ZOTHER', 'Name': 'example.net.'}
        client = Mock()
        with patch.dict('sys.modules', {'boto3': SimpleNamespace(client=Mock(return_value=client))}):
            client.list_hosted_zones_by_name.return_value = {'HostedZones': [public, other], 'IsTruncated': False}
            self.assertEqual(module.get_hosted_zone_id('EXAMPLE.COM.'), 'ZPUBLIC')
            client.list_hosted_zones_by_name.assert_called_with(DNSName='example.com.', MaxItems='2')
            client.list_hosted_zones_by_name.return_value = {'HostedZones': [public, private], 'IsTruncated': False}
            with self.assertRaisesRegex(ValueError, '--hosted-zone-id'):
                module.get_hosted_zone_id('example.com')
            client.list_hosted_zones_by_name.side_effect = [
                {'HostedZones': [public], 'IsTruncated': True, 'NextDNSName': 'example.com.', 'NextHostedZoneId': 'ZPRIVATE'},
                {'HostedZones': [private, other], 'IsTruncated': False},
            ]
            with self.assertRaisesRegex(ValueError, '--hosted-zone-id'):
                module.get_hosted_zone_id('example.com')
            client.list_hosted_zones_by_name.assert_called_with(DNSName='example.com.', HostedZoneId='ZPRIVATE', MaxItems='2')
            client.get_hosted_zone.return_value = {'HostedZone': private}
            self.assertEqual(module.get_hosted_zone_id('example.com.', '/hostedzone/ZPRIVATE'), 'ZPRIVATE')
            client.get_hosted_zone.assert_called_with(Id='ZPRIVATE')
            client.get_hosted_zone.return_value = {'HostedZone': other}
            with self.assertRaisesRegex(ValueError, 'does not belong'):
                module.get_hosted_zone_id('example.com', 'ZOTHER')
            client.list_hosted_zones_by_name.side_effect = None
            client.list_hosted_zones_by_name.return_value = {'HostedZones': [other], 'IsTruncated': False}
            with self.assertRaisesRegex(ValueError, 'No hosted zone exactly matches'):
                module.get_hosted_zone_id('example.com')

    def test_dns_inventory_is_operator_supplied(self):
        path = ROOT / 'aws/terraform/scripts/update_route53.py'
        spec = importlib.util.spec_from_file_location('route_commands', path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as directory:
            records = Path(directory, 'domains.json')
            records.write_text(json.dumps({'example.net': ['service.example.net']}))
            with patch('builtins.input', return_value='1'), contextlib.redirect_stdout(io.StringIO()):
                domain, names = module.choose_domain(records)
            commands = module.generate_aws_commands(domain, names, 'example.elb.amazonaws.com', 'ZELB', 'ZDOMAIN')
            args = shlex.split(commands[0])
            data = json.loads(args[args.index('--change-batch') + 1])
            self.assertEqual(data['Changes'][0]['ResourceRecordSet']['Name'], 'service.example.net')
            self.assertEqual(args[args.index('--hosted-zone-id') + 1], 'ZDOMAIN')
        for invalid in (['api.other.net'], ['badexample.net'], ['service.example.net', 'api.other.net']):
            with self.assertRaisesRegex(ValueError, 'outside the selected hosted zone'):
                module.generate_aws_commands('example.net', invalid, 'example.elb.amazonaws.com', 'ZELB', 'ZDOMAIN')


if __name__ == '__main__':
    unittest.main()
