# ── Inflate Deployment ────────────────────────────────────────────────────────
# Holds spare capacity by running low-priority pause containers sized to consume
# ~1 vCPU / 1.5Gi per replica. Karpenter provisions real nodes for them, but:
#   - Real workloads can preempt them (low PriorityClass)
#   - Karpenter consolidation can still bin-pack and scale down when possible
# Adjust replicas to control how many extra nodes stay warm.

resource "kubernetes_priority_class_v1" "inflate" {
  metadata {
    name = "inflate-low"
  }
  value          = -10
  global_default = false
  description    = "Low priority class for inflate/placeholder pods"
}

resource "kubernetes_deployment_v1" "inflate" {
  metadata {
    name      = "inflate"
    namespace = "default"
    labels = {
      app = "inflate"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "inflate"
      }
    }

    template {
      metadata {
        labels = {
          app = "inflate"
        }
      }

      spec {
        priority_class_name = kubernetes_priority_class_v1.inflate.metadata[0].name

        container {
          name  = "inflate"
          image = "public.ecr.aws/eks-distro/kubernetes/pause:3.7"

          resources {
            requests = {
              cpu    = "1"
              memory = "1.5Gi"
            }
          }
        }

      }
    }
  }

  depends_on = [helm_release.karpenter]
}

# ── Load Generators ───────────────────────────────────────────────────────────
# Dedicated load generator that sends sustained HTTP traffic to the Online
# Boutique frontend service. Combined with the app's built-in Locust-based
# loadgenerator (scaled to 3 replicas), this creates enough pressure to
# trigger Karpenter to provision additional nodes.

resource "kubernetes_deployment_v1" "boutique_load_gen" {
  metadata {
    name      = "boutique-load-gen"
    namespace = "onlineboutique"
    labels = {
      app = "boutique-load-gen"
    }
  }

  spec {
    replicas = 3

    selector {
      match_labels = {
        app = "boutique-load-gen"
      }
    }

    template {
      metadata {
        labels = {
          app = "boutique-load-gen"
        }
      }

      spec {
        container {
          name  = "load-gen"
          image = "busybox:1.36"

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            while true; do
              wget -qO- http://frontend/ > /dev/null 2>&1
              wget -qO- http://frontend/product/OLJCESPC7Z > /dev/null 2>&1
              wget -qO- http://frontend/cart > /dev/null 2>&1
              wget -qO- http://frontend/recommendations > /dev/null 2>&1
              sleep 0.2
            done
          EOT
          ]

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }

        # Spread load-gen pods across nodes to drive multi-node resource pressure
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              app = "boutique-load-gen"
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.online_boutique_manifests]
}

resource "kubernetes_deployment_v1" "superheroes_load_gen" {
  metadata {
    name      = "superheroes-load-gen"
    namespace = "super-heroes"
    labels = {
      app = "superheroes-load-gen"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "superheroes-load-gen"
      }
    }

    template {
      metadata {
        labels = {
          app = "superheroes-load-gen"
        }
      }

      spec {
        container {
          name  = "load-gen"
          image = "busybox:1.36"

          command = ["/bin/sh", "-c"]
          args = [<<-EOT
            while true; do
              wget -qO- http://ui-super-heroes/ > /dev/null 2>&1
              wget -qO- http://rest-fights:8082/api/fights > /dev/null 2>&1
              wget -qO- http://rest-heroes:8083/api/heroes/random > /dev/null 2>&1
              wget -qO- http://rest-villains:8084/api/villains/random > /dev/null 2>&1
              sleep 0.5
            done
          EOT
          ]

          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
            limits = {
              cpu    = "50m"
              memory = "64Mi"
            }
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "kubernetes.io/hostname"
          when_unsatisfiable = "ScheduleAnyway"
          label_selector {
            match_labels = {
              app = "superheroes-load-gen"
            }
          }
        }
      }
    }
  }

  depends_on = [null_resource.superheroes_manifests]
}
