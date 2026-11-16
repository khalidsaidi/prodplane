output "efs_id" {
  description = "The ID of the EFS file system"
  value       = aws_efs_file_system.efs.id
}

output "efs_security_group_id" {
  description = "The Security Group ID for EFS"
  value       = aws_security_group.efs_sg.id
}

output "storage_class_name" {
  value = kubernetes_storage_class.efs_sc.metadata[0].name
}
