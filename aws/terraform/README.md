# Terraform platform components

Each directory is an independent root with its own S3 backend configuration. The network topology uses two distinct availability zones, each with one public and one private subnet; inputs are checked so extra zones or CIDRs are not silently ignored.

| Root | Responsibility |
| --- | --- |
| `clusters/network` | VPC, subnets, routing, bastion, certificate VPN and optional VPC peering |
| `clusters/security` | Platform IAM, node/cluster security groups and SSH key registration |
| `clusters/eks` | Private EKS cluster and node group |
| `clusters/storage` | Shared EFS and its dynamic access-point storage class |
| `clusters/eks_addons` | Controllers, CSI drivers, Kubernetes access mapping and configurable container-log destinations |
| `environments/app_deploy` | Namespace and caller-defined build projects, secret mirrors and ConfigMaps |
| `environments/aws_deploy` | Optional caller-defined caches and endpoint publication |
| `environments/eventbridge` | Optional event buses/build routes, event logging and schema discovery |
| `environments/storage` | Optional caller-defined claims; dynamic provisioning by default or explicit existing storage handles |

## Entry points

- `deploy_network.sh`: network infrastructure.
- `deploy_cluster.sh`: security → EKS → storage → add-ons; reverse order for cluster teardown.
- `deploy_environment.sh`: selected environment components; `--environments dev,demo` supports explicit selection.

Remove application workloads and environment resources before tearing down their cluster. Cluster teardown does not coordinate or erase the independent environment states.

Full environment teardown removes its namespace first so workloads release namespaced claims. The environment's infrastructure retention policies can still block destructive operations. A storage-only teardown requires stopping its consumers.

Automatic approval applies only to non-production. Production network/environment applies require `apply-prod`; production cluster operations retain Terraform's confirmation even if `--auto-approve` is supplied. The selected region and cluster class override conflicting values in the target variables file. The scripts resolve their Terraform root from their own path. Without execution selected they show commands. Region/environment menu choices can be set through `PRODPLANE_REGIONS` and `PRODPLANE_ENVIRONMENTS`.

## Inputs and state

Cluster examples are under `config/<cluster-class>/<region>/`. Environment examples are under `config/<cluster-class>/<environment>/<region>/`; Recovery-labelled directories can be passed directly to Terraform. They do not implement replication or failover.

Copy a matching `.tfvars.example` and `-backend.hcl.example` pair without `.example`. Configure their placeholders and make bucket, region and key prefix agree. Application maps are empty unless the operator supplies definitions. Examples for those definitions are in `deployment/examples/`.

Use Terraform 1.7+. Each root has its own input and backend configuration.

Choose an EKS version currently available in the target region using the [AWS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) or `aws eks describe-cluster-versions`. Examples intentionally require that selection instead of pinning an expired release. Managed nodes follow the selected control-plane version by default; `node_version` permits a deliberate staged upgrade. `node_disk_size` is optional and can require node-group replacement when changed. Cluster identity follows the shared `project_name` and cluster-class naming contract.

The bastion image is Debian/Ubuntu with apt/systemd, AWS CLI and `amazon-efs-utils`. Network and storage inputs share the same `efs_creation_token`, which the bastion uses for filesystem discovery. Its optional `bastion_instance_profile` must authorize EFS discovery unless another intentional credential source exists. The generated mount service waits asynchronously for EFS.

New clusters authorize the platform build/deployment roles through `aws-auth` by default, using the identity that created the cluster to apply the add-ons. This connects the roles created by security to the deployment recipe. Set `configure_aws_auth_configmap = false` only when an external owner supplies equivalent authorization. All supplied installation examples enable the platform mapping.

## Local validation

`terraform init -backend=false` and `terraform validate` check a root without initializing its remote backend. The `tests/*.tftest.hcl` cases use mock providers and override remote state; they do not operate AWS resources. Run `terraform test` after initialization to test supplied and empty application definitions.

See [configuration contracts](../../docs/configuration-contracts.md) for input requirements and component ownership.

Kubernetes providers in storage, add-ons and environment components use the endpoint, CA and cluster identity from the selected EKS state. They do not rely on the current kubeconfig context. The operator still needs AWS CLI credentials authorized on that cluster and network access to its private endpoint. EKS state supplies the endpoint, certificate, cluster name and authentication region as one contract.

The entry points reconfigure Terraform's cached backend for each selected target without migrating state. Cluster and environment teardown check all selected destroy plans before removing anything, so a known constraint in a later component fails before earlier components are deleted. Execution still re-plans each component and can fail partway through; this is not transactional teardown. Missing configuration directories are reported, and mixed configured/unconfigured selections report partial completion.

When `configure_aws_auth_configmap` is enabled, add-ons update the platform role mappings through the selected cluster provider. Existing node/operator mappings and other ConfigMap data are preserved; removing add-ons leaves `aws-auth` in place. Access removal is a separate deliberate operation. Current security state exports the build role ARN for consumers. IAM policy names include the region, matching their regional roles.

Manual build selection requires `jq` and access to the selected `app_deploy` backend. It reads `codebuild_project_arns` from that state and checks the current AWS account and selected region before starting projects. A name prefix is not used to infer ownership. Read/start failures return a failure status; `--start-codebuilds` cannot be combined with `--dry-run` or `--destroy`. The validation entry point checks Terraform configuration and supplied `.tfvars` syntax; target plans are still required to validate input expressions, types and provider constraints.

The network entry point respects `bastion_ssh_cidrs`; an empty list leaves VPN-only ingress. `--allow-current-ip` explicitly opts into adding temporary SSH access after apply, using `bastion_sg_id` from the selected state. Include the CIDR in the Terraform input to retain it across future applies.

Bastion ingress and public routes each have one Terraform owner: the bastion security group and public route tables manage their rules inline. Private routes use standalone resources. The external peer return route requires a route table whose owner permits standalone route management.

Controller chart and permission versions are paired. The EBS chart uses the supported `policy/v1` disruption-budget API and receives its region from EKS state. Load-balancer permissions follow the policy shipped with its pinned controller release. CSI and load-balancer Helm releases wait for their IAM policy attachments. See [controller policy sources and requirements](clusters/eks_addons/policies/README.md).
