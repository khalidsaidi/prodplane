resource "aws_key_pair" "eks_key_pair" {
  key_name   = "${var.cluster_environment}-eks-ssh-key"
  public_key = data.aws_secretsmanager_secret_version.ssh_key_version.secret_string

  tags = {
    Name = "${var.cluster_environment}-eks-ssh-key"
  }
}
