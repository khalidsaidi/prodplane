"""The generic chart must accept unrelated workloads without fixed service dependencies."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
HELM = os.environ.get('HELM_BIN') or shutil.which('helm')
KUBECONFORM = os.environ.get('KUBECONFORM_BIN') or shutil.which('kubeconform')


@unittest.skipUnless(HELM, 'Helm is required for chart rendering')
class ChartRendering(unittest.TestCase):
    def render(self, values, name='custom', namespace='team-a', success=True):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory, 'values.yaml')
            config.write_text(yaml.safe_dump(values))
            result = subprocess.run([HELM, 'template', name, str(ROOT / 'deployment/charts/workload'),
                                     '-n', namespace, '-f', str(config)], text=True, capture_output=True)
        if not success:
            self.assertNotEqual(result.returncode, 0)
            return result.stderr
        self.assertEqual(result.returncode, 0, result.stderr)
        if KUBECONFORM:
            check = subprocess.run([KUBECONFORM, '-strict', '-summary'], input=result.stdout, text=True, capture_output=True)
            self.assertEqual(check.returncode, 0, check.stdout + check.stderr)
        return list(yaml.safe_load_all(result.stdout))

    def test_minimal_workload_requires_no_application_services_or_secrets(self):
        resources = self.render({'image': {'repository': 'registry.example.com/team/processor', 'tag': 'v1'}})
        self.assertEqual({r['kind'] for r in resources}, {'ServiceAccount', 'Service', 'Deployment'})
        deployment = next(r for r in resources if r['kind'] == 'Deployment')
        container = deployment['spec']['template']['spec']['containers'][0]
        self.assertNotIn('env', container)
        self.assertNotIn('volumes', deployment['spec']['template']['spec'])
        self.assertEqual(container['image'], 'registry.example.com/team/processor:v1')

    def test_supplied_configuration_claim_route_and_migration_survive_rendering(self):
        values = {
            'image': {'repository': 'registry.example.com/worker', 'tag': 'v2'},
            'envFrom': [{'secretRef': {'name': 'worker-credentials'}}, {'configMapRef': {'name': 'worker-config'}}],
            'volumes': [{'name': 'files', 'persistentVolumeClaim': {'claimName': 'chosen-files'}}],
            'volumeMounts': [{'name': 'files', 'mountPath': '/data'}],
            'ingress': {'enabled': True, 'hosts': ['custom.example.net']},
            'migration': {'enabled': True, 'image': 'registry.example.com/migration:v2',
                          'command': ['sh', '-c'], 'args': ['run-user-migration'],
                          'envFrom': [{'secretRef': {'name': 'migration-credentials'}}]},
        }
        resources = self.render(values, name='processor', namespace='team-b')
        self.assertEqual({r['metadata']['namespace'] for r in resources}, {'team-b'})
        deployment = next(r for r in resources if r['kind'] == 'Deployment')
        spec = deployment['spec']['template']['spec']
        self.assertEqual(spec['volumes'], values['volumes'])
        self.assertEqual(spec['containers'][0]['envFrom'], values['envFrom'])
        ingress = next(r for r in resources if r['kind'] == 'Ingress')
        self.assertEqual(ingress['spec']['rules'][0]['host'], 'custom.example.net')
        self.assertEqual(ingress['spec']['ingressClassName'], 'alb')
        self.assertEqual(ingress['metadata']['annotations']['alb.ingress.kubernetes.io/target-type'], 'ip')
        service = next(r for r in resources if r['kind'] == 'Service')
        self.assertEqual(service['spec']['type'], 'ClusterIP')
        self.assertEqual(ingress['spec']['rules'][0]['http']['paths'][0]['backend']['service']['name'], service['metadata']['name'])
        job = next(r for r in resources if r['kind'] == 'Job')
        self.assertEqual(job['metadata']['annotations']['helm.sh/hook'], 'pre-install,pre-upgrade')
        self.assertEqual(job['spec']['template']['spec']['serviceAccountName'], 'default')
        self.assertEqual(job['spec']['template']['spec']['containers'][0]['args'], ['run-user-migration'])

    def test_worker_can_use_existing_identity_without_creating_service(self):
        resources = self.render({'image': {'repository': 'registry.example.com/worker', 'tag': 'v3'},
                                 'service': {'enabled': False}, 'serviceAccount': {'create': False, 'name': 'existing-worker'},
                                 'command': ['/app/process']})
        self.assertEqual([r['kind'] for r in resources], ['Deployment'])
        self.assertEqual(resources[0]['spec']['template']['spec']['serviceAccountName'], 'existing-worker')

    def test_stateful_workload_retains_peer_identity_and_per_replica_storage(self):
        claims = [{'metadata': {'name': 'data'}, 'spec': {'accessModes': ['ReadWriteOnce'],
                   'storageClassName': 'example-storage', 'resources': {'requests': {'storage': '5Gi'}}}}]
        resources = self.render({'kind': 'StatefulSet', 'replicaCount': 3,
                                 'image': {'repository': 'registry.example.com/stateful', 'tag': 'v1'},
                                 'volumeClaimTemplates': claims, 'volumeMounts': [{'name': 'data', 'mountPath': '/data'}],
                                 'initContainers': [{'name': 'prepare', 'image': 'registry.example.com/tools:v1', 'command': ['prepare-data']}],
                                 'extraContainers': [{'name': 'observe', 'image': 'registry.example.com/observer:v1'}]},
                                name='replicated')
        workload = next(r for r in resources if r['kind'] == 'StatefulSet')
        headless = next(r for r in resources if r['kind'] == 'Service' and r['spec'].get('clusterIP') == 'None')
        self.assertEqual(workload['spec']['serviceName'], headless['metadata']['name'])
        self.assertEqual(workload['spec']['volumeClaimTemplates'], claims)
        self.assertEqual(workload['spec']['replicas'], 3)
        self.assertTrue(headless['spec']['publishNotReadyAddresses'])
        self.assertEqual(workload['spec']['template']['spec']['initContainers'][0]['name'], 'prepare')
        self.assertEqual(workload['spec']['template']['spec']['containers'][1]['name'], 'observe')

    def test_control_flags_require_booleans_before_hooks_can_run(self):
        base = {'image': {'repository': 'registry.example.com/app', 'tag': 'v1'}}
        for group, field in [('migration', 'enabled'), ('ingress', 'enabled'),
                             ('service', 'enabled'), ('serviceAccount', 'create')]:
            with self.subTest(group=group):
                values = {**base, group: {field: 'false'}}
                if group == 'migration':
                    values[group]['image'] = 'registry.example.com/migration:v1'
                error = self.render(values, success=False)
                self.assertIn('boolean', error)
                self.assertIn(group, error)
        resources = self.render({**base, 'migration': {'enabled': False, 'image': 'registry.example.com/migration:v1'}})
        self.assertNotIn('Job', [resource['kind'] for resource in resources])

    def test_identifiers_and_image_text_are_serialized_as_data(self):
        payload = 'v1"\n        - name: injected\n          image: other/image:tag'
        resources = self.render({'nameOverride': 'false', 'image': {'repository': 'example/app', 'tag': payload}},
                                name='true', namespace='false')
        self.assertTrue(all(r['metadata']['namespace'] == 'false' for r in resources))
        deployment = next(r for r in resources if r['kind'] == 'Deployment')
        self.assertEqual(deployment['metadata']['name'], 'true')
        containers = deployment['spec']['template']['spec']['containers']
        self.assertEqual(len(containers), 1)
        self.assertEqual(containers[0]['image'], 'example/app:' + payload)
        self.assertEqual(deployment['spec']['selector']['matchLabels']['app.kubernetes.io/name'], 'false')
        self.assertIn('replicaCount', self.render({'image': {'repository': 'example/app', 'tag': 'v1'},
                                                  'replicaCount': '1\n  extra: value'}, success=False))

    def test_literal_image_override_cannot_change_other_chart_values(self):
        payload = 'v1,service.type=LoadBalancer,migration.enabled=true,migration.image=other/hook:v1'
        result = subprocess.run([HELM, 'template', 'fixture', str(ROOT / 'deployment/charts/workload'),
                                 '--set-literal', 'image.repository=example/app',
                                 '--set-literal', 'image.tag=' + payload], text=True, capture_output=True, check=True)
        resources = list(yaml.safe_load_all(result.stdout))
        self.assertNotIn('Job', [r['kind'] for r in resources])
        self.assertEqual(next(r for r in resources if r['kind'] == 'Service')['spec']['type'], 'ClusterIP')
        deployment = next(r for r in resources if r['kind'] == 'Deployment')
        self.assertEqual(deployment['spec']['template']['spec']['containers'][0]['image'], 'example/app:' + payload)

    def test_incomplete_or_conflicting_options_fail_before_deployment(self):
        self.assertIn('image.repository', self.render({}, success=False))
        base = {'image': {'repository': 'registry.example.com/app', 'tag': 'v1'}}
        self.assertIn('migration.image', self.render({**base, 'migration': {'enabled': True}}, success=False))
        self.assertIn('ingress requires service.enabled', self.render({**base, 'service': {'enabled': False}, 'ingress': {'enabled': True}}, success=False))
        self.assertIn('volumeClaimTemplates requires', self.render({**base, 'volumeClaimTemplates': [{'metadata': {'name': 'data'}}]}, success=False))


if __name__ == '__main__':
    unittest.main()
