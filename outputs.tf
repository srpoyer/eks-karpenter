output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority" {
  description = "EKS cluster CA data"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = aws_eks_cluster.main.version
}

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.eks.id
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name} --profile default"
}

output "online_boutique_url" {
  description = "Online Boutique frontend URL (via ingress-nginx LoadBalancer)"
  value       = "http://${data.kubernetes_service.ingress_nginx_lb.status[0].load_balancer[0].ingress[0].hostname}"
}

output "karpenter_interruption_queue" {
  description = "SQS queue name used by Karpenter for interruption handling"
  value       = aws_sqs_queue.karpenter_interruption.name
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN attached to Karpenter-provisioned nodes"
  value       = aws_iam_role.karpenter_node.arn
}

output "karpenter_controller_role_arn" {
  description = "IAM role ARN used by the Karpenter controller (IRSA)"
  value       = aws_iam_role.karpenter_controller.arn
}
