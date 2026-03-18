locals {
  superheroes_manifest_url = "https://raw.githubusercontent.com/quarkusio/quarkus-super-heroes/main/deploy/k8s/java21-kubernetes.yml"
}

resource "kubernetes_namespace" "superheroes" {
  metadata {
    name = "super-heroes"
  }

  depends_on = [aws_eks_access_policy_association.admin_user]
}

resource "null_resource" "superheroes_manifests" {
  triggers = {
    manifest_url = local.superheroes_manifest_url
  }

  provisioner "local-exec" {
    command = "kubectl apply -f ${local.superheroes_manifest_url} -n super-heroes || true"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kubectl delete namespace super-heroes --ignore-not-found"
  }

  depends_on = [
    kubernetes_namespace.superheroes,
    null_resource.update_kubeconfig,
  ]
}

# Route external traffic through the ingress-nginx controller.
# The manifest ships its own Ingress but we add one here with ingressClassName=nginx
# to ensure it is picked up by the ingress-nginx LoadBalancer.
resource "kubernetes_ingress_v1" "superheroes" {
  metadata {
    name      = "super-heroes"
    namespace = "super-heroes"
    annotations = {
      "nginx.ingress.kubernetes.io/proxy-read-timeout"    = "3600"
      "nginx.ingress.kubernetes.io/proxy-connect-timeout" = "60"
    }
  }

  spec {
    ingress_class_name = "nginx"

    rule {
      host = "superheroes.local"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "ui-super-heroes"
              port {
                number = 80
              }
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.superheroes_manifests]
}
