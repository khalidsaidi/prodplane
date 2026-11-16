# Install Prodplane and deploy your application

This guide installs the non-production platform in `us-west-2`, creates the `dev` environment, and builds and releases your application. It provisions real, billable AWS resources, including EKS, EC2, NAT gateways and Client VPN.

```text
Operator supplies AWS access + platform configuration
    |
    +--> network --> security --> EKS --> EFS --> add-ons
                                                    |
Developer supplies application repository            |
(Dockerfile + Helm chart + application values)        |
    |                                               |
    +--> dev configuration --> namespace + CodeBuild projects
                                   |
                                   +--> image job --> ECR
                                          | success
                                          v
                                      release job --> application in dev
```

The platform installation is shared by the environments in its cluster. If your operator has already installed it, start at [Prepare your application](#4-prepare-your-application), using the operator's cluster, region and state configuration.

## 1. Prepare your AWS account and checkout

Use an AWS identity authorized to provision the resources listed in [Terraform components](../aws/terraform/README.md), pass the platform IAM roles, and read/write Terraform state. Authenticate through your normal AWS profile or role. Use that same cluster-creator identity for the initial Kubernetes configuration.

Install Git, Bash, Terraform 1.7+, AWS CLI v2, kubectl compatible with your chosen EKS version, jq and Helm 3.12+. The machine running cluster and environment operations needs connectivity to the private EKS endpoint; this guide uses the bastion created by the network component.

```bash
git clone --branch v0.1.0 --depth 1 https://github.com/khalidsaidi/prodplane.git
cd prodplane
export AWS_REGION=us-west-2
aws sts get-caller-identity
```

Keep the checkout at this version on both your workstation and the bastion. Unless stated otherwise, commands below run from the Prodplane repository root.

Prepare these account resources before applying the platform:

| Input | What to supply |
| --- | --- |
| Terraform backend | An S3 state bucket and a DynamoDB lock table in `us-west-2`. The table's partition key is the string `LockID`. Enable bucket versioning, encryption and public-access blocking. Restrict access to your operators; state contains sensitive values. |
| Bastion AMI | An x86-64 Debian/Ubuntu image in `us-west-2` with apt, systemd, AWS CLI and `amazon-efs-utils`. Install the operator tools above on it before cluster operations. |
| Bastion instance profile | An EC2 instance profile allowing `elasticfilesystem:DescribeFileSystems` so the boot-time mount service can discover EFS. Set `bastion_instance_profile` in the network inputs. Operator provisioning credentials are configured separately. |
| Bastion SSH key | An existing EC2 key pair in `us-west-2`, with its private key available on your workstation. |
| DNS | An existing Route 53 hosted zone and an unused hostname within it for the VPN endpoint. |
| Node SSH public key | A raw OpenSSH public-key file stored in Secrets Manager as `non-prod-eks-ssh-public-key`; the security component registers the EC2 key pair from it. |

The supplied backend files use DynamoDB locking. See the [Terraform S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3) for backend permissions and setup. These backend resources are account prerequisites, outside Prodplane's nine component states.

Store the node **public** key with the supplied helper, replacing the file path:

```bash
bash aws/terraform/scripts/secret_creator.sh \
  non-prod-eks-ssh-public-key /absolute/path/to/node-key.pub
```

## 2. Configure and provision the network

On your workstation, copy the five cluster input/backend pairs. This command is for a fresh checkout; keep existing configured files when repeating an installation.

```bash
for component in network security eks storage eks_addons; do
  config_dir="aws/terraform/clusters/$component/config/non-prod/us-west-2"
  for example in "$config_dir"/*.example; do
    cp -n "$example" "${example%.example}"
  done
done
```

Edit each copied file. Keep `cluster_environment = "non-prod"`, `aws_region = "us-west-2"`, and a consistent `project_name` across components. This walkthrough uses `project_name = "prodplane"`.

In every backend `.hcl`, set your bucket and lock table. Keep the supplied component-specific `key` and `region`. In every `.tfvars`, set the same `state_bucket`, `state_region = "us-west-2"`, and `state_key_prefix = "us-west-2/"`. The keys connect independent components through remote state; each component must retain its own key.

Configure these component-specific inputs:

| Component | Required choices |
| --- | --- |
| `network` | Replace the example AMI, key-pair name, DNS hostname and hosted-zone ID. Add your instance-profile name. Replace `192.0.2.10/32` in `bastion_ssh_cidrs` with your workstation's actual public IPv4 `/32` for direct SSH. Choose two available AZs and non-overlapping network ranges. |
| `eks` | Replace `REPLACE_WITH_SUPPORTED_EKS_VERSION` with a version currently offered in this region. Review the node instance type and min/desired/max capacity. Keep `ssh_key_name = "non-prod-eks-ssh-key"`. |
| `storage` | Keep `efs_creation_token` identical to the network input. |
| `eks_addons` | Keep `configure_aws_auth_configmap = true` so the platform's build and deployment roles receive Kubernetes access. |

Find available EKS versions with `aws eks describe-cluster-versions --region us-west-2` and consult the [AWS version calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html). Choose a version in standard support and compatible node capacity available in your AZs.

The network creates Client VPN even if you use direct SSH. `vpn_users = {}` creates no user profiles; configure users if you need VPN access. An empty `bastion_ssh_cidrs` list allows SSH through the VPN only.

Preview the selected commands, then apply:

```bash
bash aws/terraform/deploy_network.sh --cluster-env non-prod --region us-west-2
bash aws/terraform/deploy_network.sh --cluster-env non-prod --region us-west-2 --execute
```

Review the Terraform plan and confirm the apply. Locate the `non-prod-bastion` instance in EC2 and connect to its Elastic IP using your AMI's SSH username and the private key matching `bastion_key_name`.

## 3. Provision the private cluster

On the bastion, install the operator tools, clone the same `v0.1.0` checkout, and configure the authorized AWS identity. Securely transfer the configured `.tfvars` and backend `.hcl` pairs, or recreate the same values there. These files are Git-ignored: cloning alone does not supply them. Do not copy Terraform's `.terraform` directories or workstation credential files.

From the bastion's Prodplane checkout:

```bash
export AWS_REGION=us-west-2
mkdir -p "$HOME/.kube"
export KUBECONFIG="$HOME/.kube/prodplane-non-prod-us-west-2"
aws sts get-caller-identity
bash aws/terraform/deploy_cluster.sh --cluster-env non-prod --region us-west-2
bash aws/terraform/deploy_cluster.sh --cluster-env non-prod --region us-west-2 --execute
```

The script applies security → EKS → storage → add-ons, prompting for each apply. It configures the selected kubeconfig after creating EKS. Retain the `AWS_REGION` and `KUBECONFIG` settings for the remaining operator commands.

Check that nodes and controllers are ready before creating the application environment:

```bash
kubectl get nodes
kubectl get pods -A
kubectl get storageclass efs-sc
```

Expect Ready nodes and running controller/logging pods. Diagnose pending or failing components before continuing. The platform is now installed; application workloads arrive through the following steps.

## 4. Prepare your application

Use your own application's GitHub repository. It supplies:

```text
application/
├── Dockerfile                 builds your application image
├── charts/workload/           your Helm chart, or the supplied workload chart
└── deploy.values.yaml         your ports, probes, resources and runtime settings
```

The build recipe uses `Dockerfile` at the repository root by default; `DOCKERFILE` and `BUILD_CONTEXT` can select other paths. The release recipe expects chart inputs named `image.repository` and `image.tag`.

To use Prodplane's optional chart, copy it into your application checkout **on your development workstation**:

```bash
mkdir -p /absolute/path/to/application/charts
cp -R deployment/charts/workload /absolute/path/to/application/charts/workload
```

For an HTTP application listening on port 8080, a starting `deploy.values.yaml` is:

```yaml
containerPort: 8080
service:
  port: 80
readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 5
  periodSeconds: 10
```

Replace the port and health path with your application's actual interface. Add its required environment variables, secrets, resources and storage settings; see the [chart documentation](../deployment/charts/workload/README.md). The release job supplies the image coordinates. This first release uses a private ClusterIP Service; ingress is configured separately below.

Commit and push the Dockerfile, chart and values to the application repository. Record the full source commit and choose a unique image tag for it. Both CodeBuild projects must use that commit and tag. Authorize [CodeBuild's GitHub source access](https://docs.aws.amazon.com/codebuild/latest/userguide/access-tokens-github.html) in this AWS account and region before starting builds; Prodplane does not create source credentials.

On the operator host, create your ECR repository (this example uses `example`; replace it with your application name):

```bash
bash aws/terraform/scripts/create_ecr.sh example
```

Record its URI: `<account-id>.dkr.ecr.us-west-2.amazonaws.com/example`.

## 5. Configure the dev environment and delivery projects

On the bastion, copy the environment inputs:

```bash
config_dir=aws/terraform/environments/app_deploy/config/non-prod/dev/us-west-2
for example in "$config_dir"/*.example; do
  cp -n "$example" "${example%.example}"
done
```

Set the same project and state inputs used for the cluster, your actual `aws_account_id`, and `region_deploy_artifact = "us-west-2"`. Set the backend bucket and lock table, retaining the supplied dev-specific state key.

In the copied `.tfvars`, **replace** `codebuild_projects = {}` with the map from [the paired build-project example](../deployment/examples/build-project.tfvars.example). Do not append a second assignment. Configure:

| Field | Value |
| --- | --- |
| Both `repository_url` fields | Your application GitHub repository URL |
| Both `source_version` fields | The full commit containing the Dockerfile, chart and values |
| Image runner `image` | A CodeBuild-compatible Linux image containing Docker and AWS CLI; keep `privileged_mode = true` |
| Release runner `image` | A CodeBuild-compatible Linux image containing AWS CLI and Helm 3.12+ |
| Both `IMAGE_REPOSITORY` values | Your ECR URI in `us-west-2` (the project example shows `us-east-1`; replace it) |
| Both `IMAGE_TAG` values | The same unique release tag, for example `release-001` |
| `RELEASE_NAME` | Your application name; commands below use `example` |
| `HELM_CHART`, `HELM_VALUES_FILE` | `charts/workload`, `deploy.values.yaml` in your application repository |

Leave the example's `AUTO` values in place; Prodplane resolves the cluster, role, region and namespace from the selected environment. The runner images are build tools, distinct from the application image being built. Make them pullable by CodeBuild and check their tool versions before use.

If the application needs platform-managed secrets or ConfigMaps, supply `application_secrets` and `config_maps` now using the [configuration contracts](configuration-contracts.md). Empty maps are appropriate only when the application needs neither. Optional caches, storage claims and event routes use their own [environment components](../aws/terraform/README.md).

```bash
bash aws/terraform/deploy_environment.sh \
  --cluster-env non-prod --region us-west-2 --environments dev \
  --component app_deploy --execute
```

Review and confirm the apply. It creates the `dev` namespace and projects `dev-image` and `dev-release`. It does not start either job.

## 6. Build, release and reach the application

Start **only** `dev-image` in the project selector:

```bash
bash aws/terraform/deploy_environment.sh \
  --cluster-env non-prod --region us-west-2 --environments dev --start-codebuilds
```

Open that run in AWS CodeBuild and wait for its final status to be **SUCCEEDED**. Build logs are under `/aws/codebuild/dev/image`. A failed build must be resolved before release; finding an image tag alone does not establish success.

Run the same selector again and start **only** `dev-release`. Wait for **SUCCEEDED**; release logs are under `/aws/codebuild/dev/release`. The recipe waits for Helm readiness and the example enables atomic rollback on failure. Selecting both jobs at once does not sequence them or wait for the image build.

From the bastion, inspect the release and application:

```bash
helm status example --namespace dev
kubectl -n dev get deployments,pods,services
kubectl -n dev logs -l app.kubernetes.io/instance=example --tail=100
kubectl -n dev port-forward service/example 8080:80
```

Keep the port-forward running. In a second bastion shell, request your application's endpoint:

```bash
curl --fail http://127.0.0.1:8080/health
```

Use the actual application path configured earlier. To access this forwarded port from your workstation, create an SSH tunnel with `-L 8080:127.0.0.1:8080` to the bastion, then open `http://127.0.0.1:8080` locally. This verifies the application through its Kubernetes Service.

For an application hostname, enable ingress in the application values, set `ingress.hosts`, and choose the ALB scheme. The supplied chart uses internal ALBs by default; public exposure requires `alb.ingress.kubernetes.io/scheme: internet-facing`. Set an appropriate ALB health-check path and, for HTTPS, an ACM certificate/listener configuration. See [deployment settings](../deployment/README.md).

Commit those changes, select the new source revision and image tag in both projects, reapply `app_deploy`, and repeat the successful image → release sequence. Obtain the ALB hostname with `kubectl -n dev get ingress` and point the application's DNS record to it. The [Route 53 helper](../deployment/README.md#operator-tools) discovers load balancers and generates alias commands for you to review and execute.

## Add another environment

Copy and configure the `staging` example pairs in the selected environment components, with distinct backend keys and `environment = "staging"`. Keep their shared-state inputs pointed at the same non-production cluster. Apply with `--environments staging`.

To promote a tested application, configure staging's release project with the tested source revision and existing image tag, then run that release project. There is no need to rebuild the image. Production uses its own cluster and configuration. The [configuration hierarchy](../README.md#one-system-environments-defined-by-configuration) explains how to add or omit environments without changing the implementation.
