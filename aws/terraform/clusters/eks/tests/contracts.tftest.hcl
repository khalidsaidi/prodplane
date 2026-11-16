mock_provider "aws" {}
mock_provider "aws" { alias = "default" }
mock_provider "tls" {}
override_data {
  target = data.terraform_remote_state.network
  values = { outputs = { private_subnet_ids = ["subnet-12345678", "subnet-87654321"], bastion_sg_id = "sg-12345678" } }
}
override_data {
  target = data.terraform_remote_state.security
  values = { outputs = {
    eks_cluster_role_arn    = "arn:aws:iam::111122223333:role/cluster"
    eks_node_group_role_arn = "arn:aws:iam::111122223333:role/nodes"
    eks_nodes_sg_id         = "sg-87654321"
  } }
}
variables {
  aws_region                  = "us-east-1"
  cluster_environment         = "non-prod"
  eks_version                 = "1.32"
  node_instance_type          = "t3.medium"
  node_group_desired_capacity = 2
  node_group_min_capacity     = 1
  node_group_max_capacity     = 3
  ssh_key_name                = "fixture"
}
run "nodes_follow_cluster" {
  command = plan
  assert {
    condition     = aws_eks_node_group.default.version == aws_eks_cluster.this.version
    error_message = "A control-plane upgrade must also target the managed node version by default."
  }
}
run "staged_node_upgrade_and_explicit_disk" {
  command = plan
  variables {
    node_version   = "1.31"
    node_disk_size = 60
  }
  assert {
    condition     = aws_eks_node_group.default.version == "1.31" && aws_eks_node_group.default.disk_size == 60
    error_message = "Explicit staging and disk choices must reach the managed node group."
  }
}
