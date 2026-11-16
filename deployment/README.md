# Application-neutral deployment templates

## Workload chart

Use `charts/workload` as a small optional template, or use an application-owned chart. Supply `image.repository` and `image.tag`; the platform does not build in a runtime, application topology or database.

```bash
helm template example deployment/charts/workload \
  --namespace example \
  -f deployment/examples/workload.values.yaml.example
```

Native Kubernetes `env`, `envFrom`, `volumes`, `volumeMounts`, probes and resource settings belong to the application. Refer to secrets, ConfigMaps and claims created by the platform inputs or another explicitly selected owner.

Use `kind: StatefulSet` for stable replica identities and supply native `volumeClaimTemplates` for per-replica storage. The chart creates a headless peer-discovery Service; it does not impose a database, search engine, primary/replica protocol or application schema.

Ingress is opt-in and defaults to Prodplane's `alb` class with IP targets, matching the chart's ClusterIP Service. Applications supply hosts and any annotations for public exposure, health checks and ACM certificates. Without a scheme override, the controller creates an internal load balancer. Migrations are opt-in and take a caller image/command/environment. Their default hooks run before install and upgrade; their service account and any dependencies must already exist. Successful migration jobs are deleted; failed jobs remain for inspection. A failed job fails the Helm operation. The chart does not reverse application data changes.

## Build and deployment recipes

`buildspecs/build-image.yml` builds a Dockerfile from the application source repository and pushes the selected image tag to a private ECR registry. The registry hostname is checked before requesting a credential, and its region determines authentication; `ARTIFACT_REGION` independently selects CodeArtifact input and defaults to the registry region. It requires AWS CLI and Docker in a privileged CodeBuild runner. It has no package-format or language assumption. Set `ARTIFACT_ASSET` to first retrieve a published CodeArtifact asset; supply its domain, repository, format, package, version, namespace when required, optional owner, and `ARTIFACT_OUTPUT` path. The application Dockerfile decides how to package those bytes.

`buildspecs/deploy-helm.yml` deploys a caller-selected chart and image, waits for readiness, and optionally enables Helm's atomic rollback. Its runner must contain AWS CLI and Helm 3.12+. Image coordinates use literal Helm overrides; caller-owned charts using this recipe must consume `image.repository` and `image.tag`. Other chart interfaces can use application-owned buildspecs. It uses the namespace already created by the platform.

The `app_deploy` Terraform root can embed either recipe through `buildspec_template`, so applications do not need a copy of the platform repository in their build workspace. A local chart path refers to the application source workspace; an OCI chart reference is also accepted. Vendor or publish the optional workload chart if selecting it for delivery.

The image recipe publishes to ECR and writes its receipt under the reserved `.prodplane-build/` output directory. CodeBuild exports the receipt as `image.json`. Previous receipts are cleared before input validation, and a new receipt appears only after a successful push; application-owned source files named `image.json` are left intact. CodeBuild projects default to `NO_ARTIFACTS`; select `artifacts.type = "S3"` and a destination bucket to retain that receipt or other files declared by an application buildspec. Output storage, packaging and any KMS key are explicit project inputs. Release automation must check the overall CodeBuild result: [artifact upload is attempted even after a failed build](https://docs.aws.amazon.com/codebuild/latest/userguide/view-build-details-phases.html).

Examples under `examples/` are inputs for the corresponding Terraform root; they are not a bundled application. In particular, the build-project example needs a real source repository, runner image and registry repository.

The paired `image` and `release` projects in `examples/build-project.tfvars.example` form the manual delivery path. Put the supplied workload chart (or a chart with the same image inputs) at `charts/workload` in the application repository, and its application values in `deploy.values.yaml`. Set both projects to the same source commit, ECR repository and unique release tag. The image runner needs Docker/AWS CLI; the release runner needs Helm/AWS CLI. GitHub source access must already be authorized in CodeBuild.

Apply those projects with the environment, then use `deploy_environment.sh --start-codebuilds` to start only the image project. Check that build's final CodeBuild result before starting the release project. The selector starts jobs independently; selecting both does not order them or wait for success. The release recipe waits for Helm readiness and the example enables atomic rollback. Promotion deploys the already-built image in the destination environment; it does not require rebuilding it. EventBridge can start the release project from an explicitly configured release-ready event instead of manual selection.

## Operator tools

`tools/artifacts.sh` performs explicit package-version operations. It requires caller coordinates (`ARTIFACT_REGION`, `ARTIFACT_DOMAIN`, `ARTIFACT_REPOSITORY`, `ARTIFACT_FORMAT`, `APP_PACKAGE`; Maven, Swift and generic packages also need `ARTIFACT_NAMESPACE`). Run `--help` for commands. There is no embedded package list, release version or retention policy. Batch copy/status/delete operations require `jq`, preserve version strings as JSON arguments, and return failure if any requested version failed or is missing from the success response. The full API response remains available for inspecting partial results.

`aws/terraform/scripts/create_ecr.sh` takes repository names and `AWS_REGION`. Existing repositories are accepted. Failed account discovery stops the operation; other creation failures are reported and produce a nonzero exit status after the requested batch is attempted.

`aws/terraform/scripts/secret_creator.sh` takes a secret name and text file, with `AWS_REGION`. Use JSON for application-secret mappings and raw OpenSSH public-key text for the node-key secret. The helper stores the supplied text without imposing application key names.

`aws/terraform/scripts/update_route53.py` generates alias commands from `--records FILE`; copy `route_records.json.example` to a private configured file if desired. Inventory keys identify hosted-zone names, and their entries are fully qualified record names. Name-based discovery requires exactly one matching zone; use `--hosted-zone-id Z...` to select a public/private or duplicate zone explicitly. The ID is checked against the chosen domain, and records outside that zone are rejected. It requires boto3 for AWS discovery, and does not execute the generated changes.

`aws/terraform/clusters/network/create_vpn_certificat.sh` is a standalone certificate utility using `VPN_DOMAIN`, `AWS_REGION` and a new `VPN_CERT_DIR`. It generates CA/server certificates and imports them into ACM. The Terraform-managed VPN has its own certificate resources.
