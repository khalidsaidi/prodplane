output "codebuild_project_arns" {
  value = { for name, project in aws_codebuild_project.this : name => project.arn }
}
