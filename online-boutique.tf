locals {
  ob_version      = "v0.10.4"
  ob_manifest_url = "https://raw.githubusercontent.com/GoogleCloudPlatform/microservices-demo/${local.ob_version}/release/kubernetes-manifests.yaml"
}

# ─── Architecture ─────────────────────────────────────────────────────────────
# Tier 1 — Presentation : frontend (Go)
# Tier 2 — Application  : 10 microservices (cart, catalog, checkout, payment,
#                          shipping, currency, recommendation, ad, email, load-gen)
# Tier 3 — Data         : Redis (cartservice backing store)
# ──────────────────────────────────────────────────────────────────────────────

data "kubernetes_service" "ingress_nginx_lb" {
  metadata {
    name      = "ingress-nginx-controller"
    namespace = "ingress-nginx"
  }
  depends_on = [helm_release.ingress_nginx]
}

resource "kubernetes_namespace" "online_boutique" {
  metadata {
    name = "onlineboutique"
  }

  depends_on = [aws_eks_access_policy_association.admin_user]
}

resource "null_resource" "online_boutique_manifests" {
  triggers = {
    version = local.ob_version
  }

  provisioner "local-exec" {
    command = <<-EOT
      kubectl apply -f ${local.ob_manifest_url} -n onlineboutique
      kubectl delete service frontend-external -n onlineboutique --ignore-not-found
      kubectl scale deployment loadgenerator --replicas=3 -n onlineboutique
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete namespace onlineboutique --ignore-not-found"
  }

  depends_on = [
    kubernetes_namespace.online_boutique,
    aws_eks_node_group.main,
    null_resource.update_kubeconfig,
  ]
}

# Route external traffic through the ingress-nginx controller
resource "kubernetes_ingress_v1" "online_boutique" {
  metadata {
    name      = "onlineboutique"
    namespace = "onlineboutique"
    annotations = {
      "nginx.ingress.kubernetes.io/proxy-read-timeout"    = "3600"
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" = "60"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "frontend"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.online_boutique_manifests]
}
