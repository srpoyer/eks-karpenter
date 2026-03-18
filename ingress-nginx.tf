resource "helm_release" "ingress_nginx" {
  name             = "ingress-nginx"
  repository       = "https://kubernetes.github.io/ingress-nginx"
  chart            = "ingress-nginx"
  namespace        = "ingress-nginx"
  create_namespace = true
  version          = "4.12.0"

  set {
    name  = "controller.replicaCount"
    value = "3"
  }

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }

  # Spread pods across nodes
  set {
    name  = "controller.topologySpreadConstraints[0].maxSkew"
    value = "1"
  }
  set {
    name  = "controller.topologySpreadConstraints[0].topologyKey"
    value = "kubernetes.io/hostname"
  }
  set {
    name  = "controller.topologySpreadConstraints[0].whenUnsatisfiable"
    value = "ScheduleAnyway"
  }
  set {
    name  = "controller.topologySpreadConstraints[0].labelSelector.matchLabels.app\\.kubernetes\\.io/name"
    value = "ingress-nginx"
  }

  depends_on = [
    aws_eks_node_group.main,
    aws_eks_access_policy_association.admin_user,
  ]
}
