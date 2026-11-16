# Controller IAM policies

The `prod` and `non-prod` policy files use the upstream policy for AWS Load Balancer Controller **v2.8.1**, matching chart **1.8.1** in `load_balancer_controller.tf`.

Source: https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v2.8.1/docs/install/iam_policy.json

The policy covers the controller's AWS integrations, including ACM certificate discovery and optional ALB authentication. These are controller capabilities, not bundled application services. Keep the policy aligned when changing the controller version. The upstream Apache 2.0 license is included in `LICENSE.aws-load-balancer-controller`.

The EBS driver uses chart **2.67.2** / driver **v1.67.2** with AWS's [AmazonEBSCSIDriverPolicyV2](https://docs.aws.amazon.com/aws-managed-policy/latest/reference/AmazonEBSCSIDriverPolicyV2.html). The managed-policy ARN is `arn:aws:iam::aws:policy/AmazonEBSCSIDriverPolicyV2` (there is no `service-role/` path). Dynamic volumes receive the driver's ownership tags automatically. Externally created EBS volumes and snapshots need the permitted ownership tags, normally `ebs.csi.aws.com/cluster=true`; customer-managed KMS keys require corresponding key permissions. See the [driver's permission contract](https://github.com/kubernetes-sigs/aws-ebs-csi-driver/blob/v1.67.2/docs/install.md#set-up-driver-permissions).
