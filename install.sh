#!/usr/bin/env bash
# install.sh — Full install of the EKS + Karpenter stack.
#
# Uses a two-phase Terraform apply because the Helm and Kubernetes providers
# require a live cluster endpoint to initialize, and the cluster is created in
# the same configuration.
#
# Phase 1: AWS infrastructure + EKS cluster (~10-12 min)
# Phase 2: Karpenter, ingress-nginx, applications, load generators (~2 min)
# Phase 3: Post-apply RBAC / MongoDB fixes for rest-fights

set -euo pipefail

# ─── Helpers ────────────────────────────────────────────────────────────────

log() { echo ""; echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
  local missing=()
  for cmd in terraform aws kubectl helm; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# ─── Phase 1: Cluster infrastructure ────────────────────────────────────────

phase1_apply() {
  log "Phase 1: Applying cluster infrastructure (VPC, IAM, EKS, Karpenter SQS)..."
  terraform apply \
    -target=aws_vpc.eks \
    -target=aws_subnet.private \
    -target=aws_subnet.public \
    -target=aws_internet_gateway.eks \
    -target=aws_eip.nat \
    -target=aws_nat_gateway.eks \
    -target=aws_route_table.public \
    -target=aws_route_table.private \
    -target=aws_route_table_association.public \
    -target=aws_route_table_association.private \
    -target=aws_security_group.eks_cluster \
    -target=aws_iam_role.eks_cluster \
    -target=aws_iam_role.eks_nodes \
    -target=aws_iam_role.karpenter_node \
    -target=aws_iam_role.karpenter_controller \
    -target=aws_iam_role_policy_attachment.eks_cluster_policy \
    -target=aws_iam_role_policy_attachment.eks_worker_node_policy \
    -target=aws_iam_role_policy_attachment.eks_cni_policy \
    -target=aws_iam_role_policy_attachment.ec2_container_registry_readonly \
    -target=aws_iam_role_policy_attachment.karpenter_node_worker \
    -target=aws_iam_role_policy_attachment.karpenter_node_cni \
    -target=aws_iam_role_policy_attachment.karpenter_node_ecr \
    -target=aws_iam_role_policy_attachment.karpenter_node_ssm \
    -target=aws_iam_instance_profile.karpenter_node \
    -target=aws_iam_policy.karpenter_controller \
    -target=aws_iam_role_policy_attachment.karpenter_controller \
    -target=aws_iam_openid_connect_provider.eks \
    -target=aws_launch_template.eks_nodes \
    -target=aws_eks_cluster.main \
    -target=aws_eks_node_group.main \
    -target=aws_eks_access_entry.admin_user \
    -target=aws_eks_access_policy_association.admin_user \
    -target=aws_eks_access_entry.karpenter_node \
    -target=aws_ec2_tag.private_subnet_karpenter \
    -target=aws_ec2_tag.cluster_primary_sg_karpenter \
    -target=aws_sqs_queue.karpenter_interruption \
    -target=aws_sqs_queue_policy.karpenter_interruption \
    -target=aws_cloudwatch_event_rule.karpenter_interruption \
    -target=aws_cloudwatch_event_target.karpenter_interruption \
    -target=null_resource.update_kubeconfig \
    -auto-approve
}

# ─── Phase 2: Applications ──────────────────────────────────────────────────

phase2_apply() {
  log "Phase 2: Applying Karpenter, ingress-nginx, applications, and load generators..."
  terraform apply -auto-approve
}

# ─── Phase 3: Post-apply fixes for rest-fights ──────────────────────────────

fix_rest_fights() {
  log "Phase 3: Applying post-deploy fixes for Super Heroes rest-fights..."

  log "  Creating endpoint-reader Role and RoleBinding for rest-fights..."
  kubectl apply -n super-heroes -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: rest-fights-endpoint-reader
  namespace: super-heroes
rules:
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: rest-fights-endpoint-reader
  namespace: super-heroes
subjects:
- kind: ServiceAccount
  name: rest-fights
  namespace: super-heroes
roleRef:
  kind: Role
  name: rest-fights-endpoint-reader
  apiGroup: rbac.authorization.k8s.io
EOF

  log "  Patching view-jobs Role to add list/watch verbs..."
  kubectl patch role view-jobs -n super-heroes --type=json \
    -p='[{"op":"replace","path":"/rules/0/verbs","value":["get","list","watch"]}]'

  log "  Patching fights-db to cap WiredTiger cache and add memory limits..."
  kubectl patch deployment fights-db -n super-heroes --type=json -p='[
    {"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"memory":"512Mi","cpu":"100m"},"limits":{"memory":"1Gi","cpu":"500m"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/args","value":["--wiredTigerCacheSizeGB","0.25"]}
  ]'

  log "  Waiting for fights-db rollout..."
  kubectl rollout status deployment/fights-db -n super-heroes --timeout=180s

  log "  Recreating Liquibase MongoDB init job..."
  kubectl delete job rest-fights-liquibase-mongodb-init -n super-heroes --ignore-not-found
  kubectl apply -n super-heroes -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: rest-fights-liquibase-mongodb-init
  namespace: super-heroes
  labels:
    app: rest-fights
    application: fights-service
    system: quarkus-super-heroes
spec:
  template:
    spec:
      serviceAccountName: rest-fights
      restartPolicy: Never
      containers:
      - name: rest-fights-liquibase-mongodb-init
        image: quay.io/quarkus-super-heroes/rest-fights:java21-latest
        envFrom:
        - secretRef:
            name: rest-fights-config-creds
        - configMapRef:
            name: rest-fights-config
        env:
        - name: QUARKUS_INIT_AND_EXIT
          value: "true"
        - name: QUARKUS_LIQUIBASE_MONGODB_ENABLED
          value: "true"
EOF

  log "  Waiting for Liquibase init job to complete..."
  kubectl wait --for=condition=complete job/rest-fights-liquibase-mongodb-init \
    -n super-heroes --timeout=180s

  log "  Restarting rest-fights deployment..."
  kubectl rollout restart deployment/rest-fights -n super-heroes
  kubectl rollout status deployment/rest-fights -n super-heroes --timeout=180s
}

# ─── Summary ────────────────────────────────────────────────────────────────

print_summary() {
  log "Install complete."
  echo ""
  echo "Online Boutique URL:"
  terraform output -raw online_boutique_url 2>/dev/null || \
    kubectl get svc ingress-nginx-controller -n ingress-nginx \
      -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}'
  echo ""
  echo ""
  echo "Super Heroes (requires Host header or /etc/hosts entry for 'superheroes.local'):"
  LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "$LB" ]]; then
    echo "  curl -H 'Host: superheroes.local' http://$LB"
  fi
  echo ""
  echo "Useful commands:"
  echo "  kubectl get nodes"
  echo "  kubectl get pods -n onlineboutique"
  echo "  kubectl get pods -n super-heroes"
  echo "  kubectl get nodeclaim -w"
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  check_prereqs

  log "Initializing Terraform..."
  terraform init

  phase1_apply
  phase2_apply
  fix_rest_fights
  print_summary
}

main "$@"
