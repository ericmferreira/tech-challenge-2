output "cluster_name" {
  value       = module.eks.cluster_name
  description = "EKS cluster name."
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Kubernetes API endpoint."
}

output "ecr_repository_urls" {
  value       = { for name, repo in aws_ecr_repository.service : name => repo.repository_url }
  description = "ECR image repository URLs keyed by service name."
}

output "configure_kubectl" {
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  description = "Command to configure kubectl."
}

output "aws_region" {
  value       = var.aws_region
  description = "AWS region configured for this lab."
}
