# Prodplane

**Your path to production.**

Prodplane delivers one opinionated AWS/EKS system for running applications: a two-zone network with private worker nodes, VPN/bastion access, CodeBuild delivery, EFS storage, an AWS load balancer controller and container logging. Applications supply their code and runtime requirements; the platform supplies this architecture.

The same Terraform roots, scripts and delivery recipes serve every environment. Configuration selects the cluster, region, environment settings and requested resources. Trusted operators use those inputs to provision and operate the system.

**[Get started: install the platform and deploy your application](docs/getting-started.md)** · [Releases](https://github.com/khalidsaidi/prodplane/releases) · [Apache-2.0 license](LICENSE)

## One system, environments defined by configuration

**The architecture is fixed; the environment inventory is configurable.** Prodplane's standard lifecycle names are `sandbox`, `dev`, `test`, `staging` and `prod`, following AWS's environment terminology. Use `demo` for demonstrations and `<environment>-recovery` for recovery targets. Provision the environments you need through configuration; the Terraform roots, scripts and delivery recipes remain shared.

Production and non-production have separate clusters. Application environments such as `dev`, `demo` and `staging` share the selected non-production cluster, each with its own namespace and environment resources. For example, in `us-east-1`:

```text
SAME PRODPLANE IMPLEMENTATION: Terraform roots + scripts + recipes
    |
    +-- non-prod cluster config --> Non-production VPC + EKS
    |       |
    |       +-- dev config -------> dev namespace + resources
    |       +-- staging config ---> staging namespace + resources
    |       +-- demo config ------> demo namespace + resources
    |       +-- dev-recovery -----> development recovery namespace
    |       +-- your config ------> another environment
    |
    +-- prod cluster config ------> Production VPC + EKS
            |
            +-- prod config ------> prod namespace + resources
            +-- prod-recovery ----> production recovery namespace
            +-- your config ------> another environment
```

Cluster configuration sets the shared infrastructure; environment configuration sets application configuration, secret mappings, build projects and optional claims, caches and event routes. Each component and target has a separate Terraform state. Environment components read the selected cluster's shared outputs.

**Environment configuration hierarchy: cluster class → environment → region.** This hierarchy repeats inside each environment component. Cluster configuration uses cluster class → region, because its infrastructure is shared by the environments in that regional cluster.

The supplied `app_deploy` configuration illustrates the full environment hierarchy:

```text
aws/terraform/environments/app_deploy/config/
├── non-prod/                    cluster class
│   ├── dev/                     environment
│   │   ├── us-east-1/           region
│   │   └── us-west-2/
│   ├── staging/
│   │   ├── us-east-1/
│   │   └── us-west-2/
│   ├── demo/
│   │   ├── us-east-1/
│   │   └── us-west-2/
│   └── dev-recovery/
│       ├── us-east-1/
│       └── us-west-2/
└── prod/                        cluster class
    ├── prod/                    environment
    │   ├── us-east-1/
    │   ├── us-west-2/
    │   └── eu-west-1/
    └── prod-recovery/           environment + recovery purpose
        ├── us-east-1/
        └── us-west-2/
```

`prod/prod-recovery/us-west-2` therefore means **production cluster class**, **production recovery environment**, **region `us-west-2`**. The first `prod` chooses the shared cluster and production safeguards; `prod-recovery` is the environment's namespace. The region is a separate level, so it does not need to be embedded in the environment name.

| Configuration level | Location within each component |
| --- | --- |
| Cluster | `clusters/<component>/config/<cluster-class>/<region>/` |
| Application environment | `environments/<component>/config/<cluster-class>/<environment>/<region>/` |

These paths are under `aws/terraform/`. Each target supplies a `.tfvars` file and a backend `.hcl` file. The repository includes matching `.example` files. Compare the [dev configuration](aws/terraform/environments/app_deploy/config/non-prod/dev/us-east-1/non-prod-dev-us-east-1.tfvars.example) with the [demo configuration](aws/terraform/environments/app_deploy/config/non-prod/demo/us-east-1/non-prod-demo-us-east-1.tfvars.example): both use the same `app_deploy` implementation while selecting their own namespace, inputs and state.

For the `app_deploy` target above, the naming convention produces:

```text
Directory:  config/prod/prod-recovery/us-west-2/
Inputs:     prod-prod-recovery-us-west-2.tfvars
Backend:    prod-prod-recovery-us-west-2-backend.hcl
State key:  us-west-2/environments/app_deploy/prod/prod-recovery/terraform.tfstate
```

The filenames repeat `<cluster-class>-<environment>-<region>`; the supplied state-key convention starts with the region and includes the component. Both identify the same target. Each other component owns its own state key for that target.

For a new environment, supply matching configuration and distinct backend keys for its selected components, pointing shared-state inputs at the intended cluster. Select it with `--environments test`, for example; `PRODPLANE_ENVIRONMENTS` also lets you set the interactive menu choices. This changes the configured targets without changing the system implementation.

The naming convention uses recognizable lifecycle terms from [AWS Prescriptive Guidance](https://docs.aws.amazon.com/prescriptive-guidance/latest/choosing-git-branch-approach/understanding-the-dev-ops-environments.html), lowercase identifiers and hyphens. Recovery names put the environment first and its purpose second, so `dev` / `dev-recovery` and `prod` / `prod-recovery` stay visibly related.

| Name | Purpose | Category | Supplied example |
| --- | --- | --- | --- |
| `sandbox` | Experiments and proofs of concept | Lifecycle | Configure if needed |
| `dev` | Development and integration | Lifecycle | Yes |
| `test` | QA, integration and acceptance testing | Lifecycle | Configure if needed |
| `staging` | Pre-production release validation | Lifecycle | Yes |
| `prod` | Production users | Lifecycle | Yes |
| `demo` | Demonstrations | Demonstration | Yes |
| `dev-recovery` | Recovery of the development environment | Recovery | Yes |
| `prod-recovery` | Recovery of the production environment | Recovery | Yes |

The supplied inventory contains six names; `sandbox` and `test` can be added with the same configuration structure. `<environment>-recovery` is Prodplane's naming convention using AWS's [recovery environment terminology](https://docs.aws.amazon.com/drs/latest/userguide/preparing-failover.html). These names identify purpose; they do not select a replication or failover strategy. Cluster classes remain `non-prod` and `prod`, which also select platform policies and production confirmations.

For [staging](https://docs.aws.amazon.com/prescriptive-guidance/latest/choosing-git-branch-approach/staging-environment.html), configure application dependencies, access, data characteristics and capacity to represent the production conditions being validated, and deploy the already-tested image. The example supplies the target configuration; its name alone does not establish production parity or a release gate.

## What Prodplane produces

This is the logical layout of one cluster installation. Production and non-production use separate installations. Application workloads, build projects, ingress, caches and event routes appear when configured.

```text
                        APPLICATION DELIVERY

Application repository
(code + Dockerfile + chart + values)
    |
    +--> CodeBuild: build ---- push image ----> ECR repository
    |
    +--> CodeBuild: release -- Helm ----------> Private EKS API

EKS worker nodes ------------ pull image ----> ECR repository
```

Both CodeBuild jobs connect to the VPC's private subnets. The release job uses the selected image reference and deploys the chart; worker nodes pull the image. Start the release after a successful build, manually or through explicitly configured event routing. Publishing an image alone does not trigger deployment. The application repository and ECR repository are supplied separately; Prodplane includes an ECR creation tool.

```text
+------------------------------ AWS REGION ------------------------------+
|                                                                        |
| +------------------ VPC: TWO AVAILABILITY ZONES -------------------+   |
| |                                                                  |   |
| | Operator --> Client VPN --> Bastion --> Private EKS API          |   |
| | Platform IAM roles and Kubernetes mappings grant access.         |   |
| |                                                                  |   |
| | Application traffic                                              |   |
| |        |                                                         |   |
| |        v                                                         |   |
| | Application Load Balancer (when ingress is enabled)              |   |
| | Internal by default; public when configured                      |   |
| |        |                                                         |   |
| |        | routes to pod IPs                                       |   |
| |        v                                                         |   |
| | +------------- EKS WORKERS IN PRIVATE SUBNETS -------------+     |   |
| | |                                                          |     |   |
| | | Application environment = Kubernetes namespace           |     |   |
| | |   - Application pods: Deployments or StatefulSets        |     |   |
| | |   - Services selecting those pods                        |     |   |
| | |   - Configuration, secrets and requested claims          |     |   |
| | | Repeat for other application environments.               |     |   |
| | |                                                          |     |   |
| | | Shared: ALB controller, EFS/EBS CSI, metrics-server      |     |   |
| | |         Fluent Bit container-log collection              |     |   |
| | +----------------------------------------------------------+     |   |
| |                                                                  |   |
| | Pods --> EFS mount targets in both zones --> Shared EFS          |   |
| | Pods --> Application caches (when configured)                    |   |
| |                                                                  |   |
| | Private outbound --> NAT (one per zone) --> Internet             |   |
| | Public subnets contain the NAT gateways and bastion.             |   |
| +------------------------------------------------------------------+   |
|                                                                        |
| Fluent Bit ----------> CloudWatch Logs (default destination)           |
|            +---------> Shared file archive (when configured)           |
|                                                                        |
| EventBridge routes --> CodeBuild jobs / event logs (optional)          |
+------------------------------------------------------------------------+
```

Prodplane provisions the shared system and the requested environment resources. Applications supply their images, charts and runtime requirements. An environment with empty application maps creates its namespace without application workloads.

## Structure

| Layer | Location and purpose |
| --- | --- |
| Shared infrastructure | `aws/terraform/clusters/`: network, security, EKS, shared EFS and cluster add-ons |
| Environments | `aws/terraform/environments/`: namespaces/build projects, optional caches, event routing/observability and optional storage claims |
| Workload template | `deployment/charts/workload/`: optional Deployment or StatefulSet, networking, per-replica claims and migration Jobs |
| Pipeline templates | `deployment/buildspecs/`: build an application Dockerfile or deploy an application Helm chart |
| Operator tools | Explicit-input artifact, registry, secret and DNS operations |

Each of the five cluster components and four environment components retains its own Terraform state. Cluster deployment runs security → EKS → storage → add-ons. Applications can use the optional workload chart or supply their own charts.

## How the system connects

1. The network establishes the two-zone VPC, outbound routing and VPN/bastion access. Subsequent Kubernetes operations need access to the private cluster endpoint, normally from the bastion, and the authorized AWS identity that created the cluster.
2. Security creates the platform identities and SSH key. EKS creates the cluster and managed nodes. Storage creates EFS and its storage class; add-ons install the controllers, logging and build-role Kubernetes authorization.
3. An environment creates its namespace, supplied configuration/secrets and build projects. Requested claims, caches and event routes are provisioned by their respective components.
4. The image job builds the selected source revision and publishes its image. After that job succeeds, the release job deploys the same image tag and the chart from that source revision. The [paired project example](deployment/examples/build-project.tfvars.example) connects the supplied recipes; starting a job is not the same as completing a release.
5. The workload runs behind its Service. Enabled chart ingress uses the installed ALB controller and IP targets; applications supply their hosts, exposure and TLS settings. Controllers supply storage and collect container logs independently of application names.

Environment removal deletes the namespace before its storage resources. Remove environments before cluster components, and the network last. Storage retention and application data recovery remain explicit decisions; teardown is not a backup operation.

## Application boundary

The application supplies its Dockerfile or image, runtime configuration, secret references, routes, storage needs and migration image/command. There are no required application service names, database schemas, identity clients, search cores, business queues or log filenames.

Application resource maps default to empty. Creating an environment creates its namespace, not a predefined application stack. Cluster logging collects Kubernetes container output and metadata independently of application names, with CloudWatch and optional persistent file output. Event logging and schema discovery are also opt-in.

## Configure and use

Follow the [getting-started guide](docs/getting-started.md) for a complete `non-prod` / `dev` installation, from AWS prerequisites through a successful application release.

Copy the selected `*.tfvars.example` and `*-backend.hcl.example` files without the `.example` suffix, then replace their account, network and state placeholders. Supply application maps explicitly; examples are under `deployment/examples/`.

```bash
bash aws/terraform/deploy_network.sh --help
bash aws/terraform/deploy_cluster.sh --help
bash aws/terraform/deploy_environment.sh --help
```

The entry points preview commands unless execution is selected. Environment selection supports `--environments dev,demo`. `PRODPLANE_REGIONS` and `PRODPLANE_ENVIRONMENTS` set interactive choices.

Use Terraform 1.7+, Bash, AWS CLI, kubectl and jq for infrastructure operations. Build runners need the tools used by their selected recipe. The image recipe requires Docker and AWS CLI; the deployment recipe requires AWS CLI and Helm 3.12+. The caller supplies the runner image.

Run the network setup locally. Continue cluster and environment setup from a machine that can reach the private EKS endpoint, normally the bastion. That machine needs the CLI tools, authorized AWS credentials, this checkout, and the selected configuration files. The `.tfvars` and backend `.hcl` files are Git-ignored: transfer them securely or materialize their examples on that machine; cloning the repository alone does not supply them.

Each component uses independent Terraform state.

## References

- [Configuration contracts](docs/configuration-contracts.md)
- [Platform/application boundary](docs/application-boundary.md)
- [Capabilities and ownership](docs/platform-capabilities.md)
- [Terraform components](aws/terraform/README.md)
- [Deployment templates and tools](deployment/README.md)

## License

Prodplane is licensed under [Apache-2.0](LICENSE). The bundled AWS Load Balancer Controller policy retains its [upstream attribution and license](aws/terraform/clusters/eks_addons/policies/README.md).
