resource "aws_security_group" "bastion_sg" {
  name        = "${var.cluster_environment}-bastion-sg"
  description = "Security group for bastion host"
  vpc_id      = aws_vpc.main_vpc.id # Reference the main VPC created

  dynamic "ingress" {
    for_each = length(var.bastion_ssh_cidrs) == 0 ? [] : [var.bastion_ssh_cidrs]
    content {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ingress.value
    }
  }

  # Keep VPN access under the same owner as the other bastion ingress rules.
  ingress {
    description     = "Allow SSH from Client VPN"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.client_vpn_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_environment}-bastion-sg"
  }
}

resource "aws_instance" "bastion" {
  ami                         = var.bastion_ami_id
  instance_type               = var.bastion_instance_type
  key_name                    = var.bastion_key_name
  subnet_id                   = aws_subnet.public_1.id
  associate_public_ip_address = true
  iam_instance_profile        = var.bastion_instance_profile

  vpc_security_group_ids = [
    aws_security_group.bastion_sg.id
  ]
  depends_on = [aws_route_table_association.public_association_1]

  tags = {
    Name = "${var.cluster_environment}-bastion"
  }

  lifecycle {
    ignore_changes = [
      security_groups,
      vpc_security_group_ids,
    ]
  }
  user_data = <<-EOF
              #!/bin/bash
              set -e


              apt-get update -y
              apt-get install -y nfs-common snapd

              # Create month point
              mkdir -p "/mnt/${var.cluster_environment}-efs"

              cat << 'SCRIPT' > /usr/local/bin/mount-efs.sh
              #!/bin/bash
              set -e
              MOUNT_POINT="/mnt/${var.cluster_environment}-efs"
              EFS_CREATION_TOKEN=$(printf '%s' '${base64encode(var.efs_creation_token)}' | base64 --decode)

              # Chercher l'EFS_ID en boucle
              while true; do
                  EFS_ID=$(aws efs describe-file-systems \
                      --region="${var.aws_region}" \
                      --creation-token="$EFS_CREATION_TOKEN" \
                      --query 'FileSystems[0].FileSystemId' \
                      --output text)

                  if [ -n "$EFS_ID" ] && [ "$EFS_ID" != "None" ]; then
                    echo "EFS found: $EFS_ID"
                    mkdir -p "/mnt/${var.cluster_environment}-efs"
                    if ! grep -qs "$MOUNT_POINT " /proc/mounts; then
                      mount -t efs -o tls "$EFS_ID:/" "/mnt/${var.cluster_environment}-efs"
                      echo "$EFS_ID:/ /mnt/${var.cluster_environment}-efs efs _netdev,tls 0 0" >> /etc/fstab
                      echo "Monting Ok."
                    else
                      echo "Already monted."
                    fi
                    break
                  else
                    echo "EFS not found, trying in 30s..."
                    sleep 30
                  fi
              done
              SCRIPT

              chmod +x /usr/local/bin/mount-efs.sh

              cat << 'UNIT' > /etc/systemd/system/mount-efs.service
              [Unit]
              Description=Mount EFS when ready
              After=network-online.target
              Wants=network-online.target

              [Service]
              Type=oneshot
              ExecStart=/usr/local/bin/mount-efs.sh
              RemainAfterExit=yes
              Restart=on-failure
              RestartSec=30

              [Install]
              WantedBy=multi-user.target
              UNIT

              systemctl daemon-reload
              systemctl enable mount-efs
              systemctl start --no-block mount-efs
              EOF
}



resource "aws_eip" "bastion_eip" {
  instance = aws_instance.bastion.id

  tags = {
    Name = "${var.cluster_environment}-bastion-eip"
  }
}

output "bastion_private_ip" {
  value = aws_instance.bastion.private_ip
}
