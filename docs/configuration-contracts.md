# Configuration contracts

## State and platform identity

Every Terraform root accepts `project_name`, `state_bucket`, `state_region` and `state_key_prefix`. Backend HCL must agree with the corresponding inputs. Shared-state readers use the existing cluster component key paths; applications do not determine those boundaries.

Examples include all required input structures. Placeholder account IDs, AMIs, SSH keys, networks and state locations must be replaced. Regional/recovery directory names are configuration labels and do not implement replication or failover. The `dev-recovery` and `prod-recovery` examples use those same names for directory selection and Kubernetes namespaces. Their backend keys use those same environment names.

Use the lifecycle names `sandbox`, `dev`, `test`, `staging` and `prod`, following [AWS environment definitions](https://docs.aws.amazon.com/prescriptive-guidance/latest/choosing-git-branch-approach/understanding-the-dev-ops-environments.html). `demo` names a demonstration target. Recovery targets use `<environment>-recovery`: the supplied examples are `dev-recovery` and `prod-recovery`. This keeps related environments together under one readable convention. Keep the directory, filename, `environment` value and backend key consistent. The cluster class (`non-prod` or `prod`) is a separate selector for shared infrastructure and operator safeguards.

## Application environment

`app_deploy` always creates the selected namespace. The following maps are optional and default to `{}`:

| Input | Contract |
| --- | --- |
| `codebuild_projects` | Caller-chosen project keys, source repository/revision, runner image, timeouts and environment variables |
| `application_secrets` | Kubernetes secret name → Secrets Manager JSON secret ID and target-key/source-key mappings |
| `config_maps` | ConfigMap name → map of non-secret strings |

A build project can name its own `buildspec` in its GitHub source repository or select `buildspec_template = "build-image"` / `"deploy-helm"`. The supplied project provisioner uses Linux runners. Local Docker-daemon builds require `privileged_mode = true`; other projects default to false. `service_role_arn` can select a caller-managed build role.

Build outputs are caller-owned too. `artifacts.type` defaults to `NO_ARTIFACTS` for jobs that publish directly to a registry. Set it to `S3` with a destination bucket in `artifacts.location` to export the buildspec's output files. Name, path, packaging and name overrides are configurable; S3 output defaults to a build-ID namespace. An optional project `encryption_key` selects a KMS key. The bucket and the build role's S3/KMS permissions must already be configured.

Plaintext build environment values marked `AUTO` resolve only these platform bindings: `EKS_CLUSTER_NAME`, `EKS_KUBECTL_ROLE_ARN`, `CLUSTER_REGION`, `ARTIFACT_REGION`, `ECR_REGISTRY`, `NAMESPACE` and `ENVIRONMENT`. Other values are supplied by the application. Secret and parameter references use CodeBuild's `SECRETS_MANAGER` and `PARAMETER_STORE` types; their identifiers are passed through literally, including an identifier named `AUTO`.

The security root expects its `<cluster-class>-eks-ssh-public-key` Secrets Manager value to be a raw OpenSSH public key. Application-secret mirroring separately expects JSON and explicit field mappings.

Secret mirroring stores the selected values in Terraform state. Secure the state backend accordingly. Applications may instead manage secrets externally and reference them directly from their charts.

## Optional infrastructure for applications

- `storage.volumes`: claim name → size, access modes and optional EFS `volume_handle`. By default, the storage class dynamically provisions an access point for the claim. An explicit handle selects existing storage instead. Its static PV reserves the requested namespace and claim through `claim_ref`, preventing another matching claim from binding it first. Default PV names separate namespace and claim with a dot (long names use a hash suffix). An optional `pv_name` selects a caller-owned physical name and requires a static `volume_handle`. The namespace/claim reservation remains explicit. Outputs expose `claim_names`.
- `aws_deploy.redis_clusters`: caller-selected cache keys, ports, encryption settings and Redis configuration. No cache is provisioned by default. Each requested cache explicitly supplies its in-transit and at-rest encryption choices. Client ingress follows the configured ports; outputs include connection port and TLS status. Authentication-token rotation remains externally managed. Endpoint parameters use the project, environment and cache key and retain destruction protection. Changing immutable cache settings can require replacement and a cutover plan.
- `eventbridge.rules`: rule key → JSON event pattern, CodeBuild target ARN and optional direct JSON input or input transformer. Permissions cover exactly the supplied targets. `event_buses` lists buses this root should create; rules can also use pre-existing buses.
- `eventbridge.log_targets`: optional event patterns routed to existing CloudWatch log-group ARNs. The module creates a resource policy limited to those groups; these targets follow the [CloudWatch Logs resource-policy model](https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-use-resource-based.html#eb-cloudwatchlogs-permissions), rather than using a CodeBuild invocation role.
- `eventbridge.schema_discovery`: optional discoverer names and source event-bus ARNs. No particular bus or schema is required by default.
- `network.peering`: optional same-account peer VPC, CIDR, route table and region. No application database network is required by default.

The namespace must exist before its claims. A full environment teardown removes the namespace first so workloads release their claims. Explicit storage-only teardown requires stopping its consumers first.

## Workload and delivery

Applications supply their image and runtime behavior. The optional chart takes native `env`, `envFrom`, `volumes`, `volumeMounts`, resource, scheduling and probe settings. Ingress and migrations are disabled by default. Migration jobs reference an existing service account because pre-install hooks run before normal chart resources are created.

The workload chart supports `kind: Deployment` and `kind: StatefulSet`. Stateful mode adds headless peer discovery and accepts per-replica `volumeClaimTemplates`; the application supplies any replication protocol and data semantics.

The build recipe uses a private-ECR `IMAGE_REPOSITORY`, `IMAGE_TAG`, optional `DOCKERFILE` and `BUILD_CONTEXT`, and `ARTIFACT_REGION` for CodeArtifact input. Registry authentication follows the region in the validated repository URI. It pushes the image only after a successful build. Its image receipt is written atomically under `.prodplane-build/` after that push. The deploy recipe takes `RELEASE_NAME`, `HELM_CHART`, optional `HELM_VALUES_FILE`, image coordinates and platform cluster/namespace inputs. It waits for Helm readiness; `HELM_ATOMIC=true` opts into Helm rollback on failure. Application SQL/data rollback is not implied.

Published-artifact input is optional: set `ARTIFACT_ASSET` together with `ARTIFACT_DOMAIN`, `ARTIFACT_REPOSITORY`, `ARTIFACT_FORMAT`, `APP_PACKAGE`, `ARTIFACT_VERSION` and `ARTIFACT_OUTPUT`. Maven, Swift and generic packages need `ARTIFACT_NAMESPACE`; `AWS_ACCOUNT_ID` selects a different domain owner when required. No artifact is fetched when this option is absent.

## Logging destinations

CloudWatch logging is enabled by default through `fluentbit_cloudwatch_enabled`. `fluentbit_persistence` optionally adds a file archive: use an existing RWX claim or let the add-ons root create one with a selected storage class and size. Each node writes its own file under the selected mount path. The collector HTTP listener, health probe and monitoring Service all use `fluentbit_http_port`. Additional native output configuration can be supplied through `fluentbit_additional_outputs`, with any required credentials/permissions arranged by the operator.

The collector image is pinned independently of the Helm chart to AWS for Fluent Bit `3.5.8` (Fluent Bit `5.1.5`).

The logging namespace owns these platform resources. Applications do not need dedicated log directories or named log classes. Retention/rotation of archive files and the choice of claim owner are operator policies.

## Operator prerequisites

The state bucket/locking setup, runner images, registry repositories and external application secrets must exist or be supplied by the operator. The bastion uses a Debian/Ubuntu AMI with apt, systemd, AWS CLI and `amazon-efs-utils`; `bastion_instance_profile` can provide EFS discovery permissions. The bastion's mount service waits asynchronously for the shared filesystem. The network and storage roots must receive the same `efs_creation_token`. Bastion discovery uses that unique identifier, independently of display tags, and passes it as literal data. VPN user-map keys are filename aliases and cannot contain path separators or control characters. Client VPN is managed by AWS and has no EC2 instance type or SSH key input.

Platform build roles use the trusted deployment-role policy. Add-ons authorize those roles for Kubernetes access by default; disabling that mapping requires an external owner to provide equivalent authorization. Application-specific permissions belong to caller-managed workload identities.

Kubernetes target identity comes from the selected EKS remote state, including its endpoint and CA. Local kubeconfig context is not a target selector for Terraform. EKS state also supplies the authentication and CodeBuild deployment region. The security state supplies the default build-role ARN. Backend initialization reconfigures the local cache for each selected target and does not migrate state.
