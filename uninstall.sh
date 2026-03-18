#!/usr/bin/env bash
# uninstall.sh — Tear down the EKS + Karpenter stack cleanly.
#
# Why this can't just be "terraform destroy":
#
#   1. ingress-nginx creates a Classic ELB in the VPC that Terraform doesn't own.
#      The VPC cannot be deleted while that ELB exists, causing DependencyViolation.
#
#   2. The ELB also leaves behind two k8s-elb-* security groups in the VPC.
#      Those must be removed before the VPC can be deleted.
#
#   3. If the cluster is deleted mid-destroy, subsequent Terraform runs can't
#      initialize the Helm/Kubernetes providers (no endpoint). The orphaned state
#      entries must be removed first so Terraform only touches AWS resources.
#
# This script handles all three cases:
#   Step 1 — Pre-clean: delete K8s namespaces so the ELB is torn down cleanly.
#   Step 2 — State rm: remove Helm/K8s/null_resource state entries that can't
#             re-initialize after the cluster is gone.
#   Step 3 — First terraform destroy: removes all AWS resources except the VPC
#             if stray ELBs/SGs are still present.
#   Step 4 — ELB + SG cleanup: find and delete anything left behind.
#   Step 5 — Final terraform destroy: removes the VPC.
#   Step 6 — Orphan purge: remove any state entries whose AWS resources were
#             already deleted outside Terraform (e.g. subnet stuck in a previous
#             failed destroy that AWS eventually cleaned up on its own).

set -euo pipefail

REGION="${TF_VAR_region:-us-west-2}"
CLUSTER_NAME="${TF_VAR_cluster_name:-$(grep -A3 'variable "cluster_name"' variables.tf | grep 'default' | sed 's/.*= *"\(.*\)".*/\1/')}"

# ─── Helpers ────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
  local missing=()
  for cmd in terraform aws kubectl jq; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required tools: ${missing[*]}"
  fi
}

# ─── Step 1: Pre-clean Kubernetes resources ─────────────────────────────────
# Delete K8s namespaces while the cluster is still alive. This triggers K8s
# finalizers on the LoadBalancer Service, which deletes the ELB before we
# start tearing down AWS resources.

preclean_kubernetes() {
  log "Step 1: Pre-cleaning Kubernetes resources..."

  if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" \
       --query 'cluster.status' --output text 2>/dev/null | grep -q ACTIVE; then
    warn "Cluster '$CLUSTER_NAME' not found or not ACTIVE — skipping K8s pre-clean."
    return
  fi

  log "  Updating kubeconfig..."
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --profile default

  log "  Deleting ingress-nginx namespace (triggers ELB deletion via K8s finalizer)..."
  kubectl delete namespace ingress-nginx --ignore-not-found --wait=false

  log "  Deleting application namespaces..."
  kubectl delete namespace onlineboutique --ignore-not-found --wait=false
  kubectl delete namespace super-heroes   --ignore-not-found --wait=false

  log "  Waiting up to 90s for the Classic ELB to be removed by the cloud-controller..."
  local vpc_id
  vpc_id=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
    --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)

  if [[ -n "$vpc_id" && "$vpc_id" != "None" ]]; then
    local deadline=$(( $(date +%s) + 90 ))
    while [[ $(date +%s) -lt $deadline ]]; do
      local elb_count
      elb_count=$(aws elb describe-load-balancers --region "$REGION" \
        --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'] | length(@)" \
        --output text 2>/dev/null || echo "0")
      if [[ "$elb_count" == "0" ]]; then
        log "  ELB removed by K8s cloud-controller."
        break
      fi
      echo "    Waiting for ELB cleanup... ($elb_count remaining)"
      sleep 10
    done
  fi
}

# ─── Step 2: State rm ───────────────────────────────────────────────────────
# Remove Helm/Kubernetes/null_resource state entries so Terraform doesn't try
# to initialize those providers when the cluster is gone.

stale_state_rm() {
  log "Step 2: Removing Helm/Kubernetes/null_resource state entries..."

  # Collect all resource addresses matching these provider prefixes
  local resources
  resources=$(terraform state list 2>/dev/null \
    | grep -E '^(helm_release|kubernetes_|null_resource)\.' || true)

  if [[ -z "$resources" ]]; then
    log "  No Helm/Kubernetes/null_resource entries in state — nothing to remove."
    return
  fi

  echo "$resources" | while read -r addr; do
    echo "    Removing: $addr"
    terraform state rm "$addr"
  done
}

# ─── Step 3: First terraform destroy ────────────────────────────────────────

first_destroy() {
  log "Step 3: Running terraform destroy (first pass)..."
  terraform destroy -auto-approve || {
    warn "terraform destroy exited non-zero — will attempt ELB/SG cleanup then retry."
  }
}

# ─── Step 4: ELB + security group cleanup ───────────────────────────────────
# ingress-nginx may leave behind a Classic ELB and k8s-elb-* SGs that prevent
# VPC deletion. Find them by VPC and delete them.

cleanup_elbs_and_sgs() {
  log "Step 4: Cleaning up any stray ELBs and security groups in the VPC..."

  # Try to get VPC ID from remaining state; fall back to tag lookup.
  local vpc_id
  vpc_id=$(terraform state show aws_vpc.eks 2>/dev/null \
    | grep '^\s*id\s' | awk '{print $3}' | tr -d '"' || true)

  if [[ -z "$vpc_id" ]]; then
    vpc_id=$(aws ec2 describe-vpcs --region "$REGION" \
      --filters "Name=tag:Name,Values=${CLUSTER_NAME}-vpc" \
      --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)
  fi

  if [[ -z "$vpc_id" || "$vpc_id" == "None" ]]; then
    log "  VPC not found — nothing to clean up."
    return
  fi

  log "  VPC: $vpc_id"

  # Delete any Classic ELBs in the VPC
  local elb_names
  elb_names=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].LoadBalancerName" \
    --output text 2>/dev/null || true)

  for name in $elb_names; do
    [[ -z "$name" ]] && continue
    log "  Deleting Classic ELB: $name"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$name"
  done

  if [[ -n "$elb_names" ]]; then
    log "  Waiting 15s for ELB deletion to propagate..."
    sleep 15
  fi

  # Delete any k8s-elb-* security groups left behind by the cloud-controller
  local sg_ids
  sg_ids=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=k8s-elb-*" \
    --query 'SecurityGroups[*].GroupId' --output text 2>/dev/null || true)

  for sg_id in $sg_ids; do
    [[ -z "$sg_id" ]] && continue
    log "  Deleting security group: $sg_id"
    aws ec2 delete-security-group --region "$REGION" --group-id "$sg_id" || \
      warn "Could not delete $sg_id (may still have dependents, will retry in final destroy)"
  done
}

# ─── Step 5: Final terraform destroy ────────────────────────────────────────

final_destroy() {
  log "Step 5: Running final terraform destroy (VPC and any remaining resources)..."
  terraform destroy -auto-approve || {
    warn "terraform destroy exited non-zero — will purge orphaned state entries and verify."
  }
}

# ─── Step 6: Purge orphaned state entries ───────────────────────────────────
# After all destroy passes, any resource still in state no longer exists in
# AWS (e.g. a subnet that was stuck in a DependencyViolation but was eventually
# cleaned up by AWS). Remove them so the state file ends up empty.

purge_orphaned_state() {
  log "Step 6: Purging any remaining orphaned state entries..."

  # Only consider managed resources, not data sources
  local remaining
  remaining=$(terraform state list 2>/dev/null \
    | grep -v '^data\.' || true)

  if [[ -z "$remaining" ]]; then
    log "  State is clean — no orphaned entries."
    return
  fi

  echo "$remaining" | while read -r addr; do
    echo "    Removing orphaned entry: $addr"
    terraform state rm "$addr"
  done

  log "  Orphan purge complete."
}

# ─── Main ───────────────────────────────────────────────────────────────────

main() {
  check_prereqs

  preclean_kubernetes
  stale_state_rm
  first_destroy
  cleanup_elbs_and_sgs
  final_destroy
  purge_orphaned_state

  log "Uninstall complete. All resources have been removed."
}

main "$@"
