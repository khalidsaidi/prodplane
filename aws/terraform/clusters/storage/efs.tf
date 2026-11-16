resource "aws_efs_file_system" "efs" {
  creation_token = var.efs_creation_token
  tags = {
    Name = var.efs_name
  }
}

# EFS Security Group
resource "aws_security_group" "efs_sg" {
  name        = "${var.cluster_environment}-efs-sg"
  description = "Security group for EFS in ${var.cluster_environment}"
  vpc_id      = data.terraform_remote_state.network.outputs.vpc_id

  ingress {
    from_port = 2049
    to_port   = 2049
    protocol  = "tcp"
    # Restricting access to private subnets
    cidr_blocks = data.terraform_remote_state.network.outputs.private_subnet_cidrs
    # add bastion
    security_groups = [data.terraform_remote_state.network.outputs.bastion_sg_id]
  }

  ingress {
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = data.terraform_remote_state.network.outputs.public_subnet_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.efs_name}-sg"
  }
}

# Create mount targets in private subnets
resource "aws_efs_mount_target" "efs_mount_target_private_a" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = element(data.terraform_remote_state.network.outputs.private_subnet_ids, 0)
  security_groups = [aws_security_group.efs_sg.id]
  depends_on      = [aws_efs_file_system.efs]
}

resource "aws_efs_mount_target" "efs_mount_target_private_b" {
  file_system_id  = aws_efs_file_system.efs.id
  subnet_id       = element(data.terraform_remote_state.network.outputs.private_subnet_ids, 1)
  security_groups = [aws_security_group.efs_sg.id]
  depends_on      = [aws_efs_file_system.efs]
}


resource "kubernetes_storage_class" "efs_sc" {
  metadata { name = "efs-sc" }
  storage_provisioner = "efs.csi.aws.com"
  reclaim_policy      = "Retain"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.efs.id
    directoryPerms   = "700"
  }
}
