variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "sp-eks-karpenter-2"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.34"
}

variable "node_instance_type" {
  description = "EC2 instance type for the system node group (Karpenter manages workload nodes)"
  type        = string
  default     = "m5.large"
}

variable "node_count" {
  description = "Number of system worker nodes (runs Karpenter, ingress-nginx, metrics-server)"
  type        = number
  default     = 3
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "karpenter_version" {
  description = "Karpenter Helm chart version"
  type        = string
  default     = "1.3.3"
}
