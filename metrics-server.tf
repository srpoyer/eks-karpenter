resource "helm_release" "metrics_server" {
  name             = "metrics-server"
  repository       = "https://kubernetes-sigs.github.io/metrics-server"
  chart            = "metrics-server"
  namespace        = "kube-system"
  version          = "3.12.2"

  set {
    name  = "args[0]"
    value = "--kubelet-insecure-tls"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_access_policy_association.admin_user,
  ]
}
