# EKS + Karpenter Terraform Stack

Provisions an Amazon EKS cluster with **Karpenter** as the node autoscaler, two microservices demo applications (Google Online Boutique and Quarkus Super Heroes), dedicated traffic load generators, ingress-nginx, and the Kubernetes metrics server — all managed through Terraform.

Karpenter replaces the Cluster Autoscaler. It provisions right-sized EC2 nodes (on-demand or spot) in seconds in response to pending pods, then consolidates or removes them when no longer needed.

---

## Architecture

```
Internet
   │
   ▼
AWS NLB (provisioned by ingress-nginx)
   │
   ├──► Online Boutique frontend  (host: <lb-hostname>)
   │         │
   │         ├──► cartservice ──► Redis (Tier 3)
   │         ├──► productcatalogservice
   │         ├──► checkoutservice ──► paymentservice
   │         │                   └──► shippingservice
   │         │                   └──► emailservice
   │         ├──► currencyservice
   │         ├──► recommendationservice
   │         └──► adservice
   │
   └──► Super Heroes UI           (host: superheroes.local)
             │
             ├──► rest-fights ──► fights-db (MongoDB)
             │              └──► fights-kafka
             │              └──► apicurio (schema registry)
             ├──► rest-heroes ──► heroes-db (PostgreSQL)
             ├──► rest-villains ──► villains-db (PostgreSQL)
             ├──► grpc-locations ──► locations-db (MongoDB)
             ├──► rest-narration
             └──► event-statistics

EKS Control Plane
   │
   ├──► System Node Group (3x m5.large, fixed)
   │        Runs: Karpenter, ingress-nginx, metrics-server, CoreDNS, kube-proxy
   │
   └──► Karpenter NodePool (dynamic, on-demand + spot)
            Runs: Online Boutique, Super Heroes, load generators
            Instance families: c, m, r (gen 3+)
            Consolidation: WhenEmptyOrUnderutilized after 1 minute
```

**Traffic generation**

Four load generators run simultaneously to keep Karpenter active:

| Generator | Namespace | Type | Replicas | Traffic pattern |
|---|---|---|---|---|
| `loadgenerator` | `onlineboutique` | Locust (built-in) | 3 | Realistic e-commerce journeys (browse, add to cart, checkout) |
| `boutique-load-gen` | `onlineboutique` | busybox wget loop | 3 | High-frequency page hits (homepage, product, cart, recommendations) |
| `superheroes-load-gen` | `super-heroes` | busybox wget loop | 2 | Hits UI, fights API, random hero, random villain endpoints |

**VPC layout**

| Subnet type | Count | Purpose |
|---|---|---|
| Public | 3 (one per AZ) | NAT gateways, NLB |
| Private | 3 (one per AZ) | System nodes, Karpenter-provisioned nodes |

---

## Stack Overview

| | `eks-tf-karpenter` |
|---|---|
| Node autoscaling | Karpenter NodePool |
| Node provisioning | System node group + Karpenter dynamic nodes |
| IAM for nodes | Separate Karpenter node role + EKS Access Entry |
| OIDC provider | Created (required for Karpenter IRSA) |
| Interruption handling | SQS queue + 4 EventBridge rules |
| Load generation | 4 load generators (8 pods total) |

---

## Quick Start

Two scripts handle the full lifecycle:

```bash
./install.sh    # Provision everything (~12–15 minutes)
./uninstall.sh  # Tear everything down cleanly
```

Both scripts check for required tools (`terraform`, `aws`, `kubectl`, `helm`, `jq`) and exit with a clear error if any are missing.

### `install.sh`

Runs the mandatory two-phase Terraform apply and applies the post-deploy fixes for the Quarkus Super Heroes `rest-fights` service automatically:

| Phase | What it does | Time |
|---|---|---|
| Phase 1 | VPC, IAM, EKS cluster, node group, Karpenter SQS/EventBridge, kubeconfig | ~10–12 min |
| Phase 2 | Karpenter, ingress-nginx, metrics-server, Online Boutique, Super Heroes, load generators | ~2 min |
| Phase 3 | RBAC fixes and MongoDB memory cap for `rest-fights`; waits for all services to be healthy | ~2 min |

### `uninstall.sh`

A plain `terraform destroy` is not enough because ingress-nginx creates an AWS Classic Load Balancer and security groups outside Terraform's management, and the Helm/Kubernetes providers cannot reinitialize after the cluster is gone. The script handles all of this:

| Step | What it does |
|---|---|
| Step 1 | Updates kubeconfig and deletes K8s namespaces, triggering the cloud-controller to delete the ELB via finalizers |
| Step 2 | Removes Helm/Kubernetes/null_resource state entries so Terraform only needs the `aws` provider for the final destroy |
| Step 3 | Runs `terraform destroy` (first pass) |
| Step 4 | Finds and deletes any remaining Classic ELBs and `k8s-elb-*` security groups in the VPC |
| Step 5 | Runs `terraform destroy` (final pass) to remove the VPC |
| Step 6 | Removes any state entries still referencing resources that AWS already deleted (e.g. a subnet stuck in a prior `DependencyViolation` that AWS cleaned up on its own) |

Both scripts respect `TF_VAR_region` and `TF_VAR_cluster_name` environment variables if you have overridden those defaults.

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| Terraform | 1.3.0 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | 2.x | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| kubectl | 1.28+ | https://kubernetes.io/docs/tasks/tools/ |
| helm | 3.x | https://helm.sh/docs/intro/install/ |

Your AWS `default` profile must have permissions to create EKS clusters, VPCs, IAM roles, SQS queues, EventBridge rules, and EC2 resources.

---

## File Reference

| File | What it does |
|---|---|
| `install.sh` | End-to-end install: `terraform init`, two-phase apply, and post-deploy `rest-fights` fixes |
| `uninstall.sh` | Full teardown: K8s namespace pre-clean, state rm, destroy, ELB/SG cleanup, final VPC destroy |
| `versions.tf` | Provider declarations (`aws`, `helm`, `kubernetes`, `null`, `tls`), provider configurations wired to the EKS cluster |
| `variables.tf` | All tunable inputs including `karpenter_version` |
| `main.tf` | VPC, internet gateway, 3 public subnets, 3 private subnets, 3 NAT gateways, route tables |
| `eks.tf` | IAM roles, security group, EKS cluster (with `API_AND_CONFIG_MAP` auth mode), OIDC provider, launch template, system node group, EKS Access Entry for the operator IAM user, `null_resource.update_kubeconfig` |
| `karpenter.tf` | SQS interruption queue, EventBridge rules, Karpenter node IAM role + instance profile, EKS Access Entry, Karpenter controller IAM role + IRSA policy, discovery tags on subnets/SG, Karpenter Helm release, EC2NodeClass, NodePool |
| `ingress-nginx.tf` | Helm release for ingress-nginx 4.12.0 with 3 replicas |
| `online-boutique.tf` | Online Boutique v0.10.4 namespace, manifests, Ingress; scales built-in `loadgenerator` to 3 replicas |
| `superheroes.tf` | Quarkus Super Heroes namespace, manifests, Ingress (host: `superheroes.local`) |
| `load-generator.tf` | `boutique-load-gen` (3 replicas, `onlineboutique`) and `superheroes-load-gen` (2 replicas, `super-heroes`) busybox wget deployments |
| `metrics-server.tf` | Helm release for metrics-server 3.12.2 |
| `outputs.tf` | Cluster info, kubeconfig command, Online Boutique URL, Karpenter queue name and role ARNs |

---

## Variables

| Variable | Default | Description |
|---|---|---|
| `region` | `us-west-2` | AWS region |
| `cluster_name` | `sp-eks-karpenter` | EKS cluster name |
| `cluster_version` | `1.34` | Kubernetes version |
| `node_instance_type` | `m5.large` | Instance type for the **system** node group |
| `node_count` | `3` | Number of system nodes (fixed; Karpenter manages workload nodes) |
| `vpc_cidr` | `10.0.0.0/16` | VPC CIDR block |
| `karpenter_version` | `1.3.3` | Karpenter Helm chart version |

---

## Running Manually

> **Tip:** Use `./install.sh` to run all of the steps below automatically. The manual steps here are provided for reference and troubleshooting.

> **Important:** The Helm and Kubernetes Terraform providers require a live cluster endpoint to initialize. Because the cluster is created in the same run, a single `terraform apply` will fail with *"no configuration has been provided"*. Always use the **two-phase apply** below.

### 1. Initialize

```bash
terraform init
```

### 2. Phase 1 — Cluster infrastructure

Apply only the AWS and cluster-level resources. This takes ~10–12 minutes.

```bash
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
```

### 3. Phase 2 — Applications

With the cluster endpoint now known, apply everything else (~2 minutes):

```bash
terraform apply -auto-approve
```

This deploys: Karpenter, ingress-nginx, metrics-server, Online Boutique, Super Heroes, and all load generators.

### 4. Post-apply: Fix Super Heroes `rest-fights`

The Super Heroes manifest ships `ServiceMonitor` CRDs (requires Prometheus Operator, not installed) and the `rest-fights` service needs two RBAC fixes and a MongoDB memory cap that are not part of the upstream manifest. Run these after Phase 2:

```bash
# Allow rest-fights ServiceAccount to list/watch endpoints (required by Stork service discovery)
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

# Allow the init container to list/watch jobs (the upstream role only grants "get")
kubectl patch role view-jobs -n super-heroes --type=json \
  -p='[{"op":"replace","path":"/rules/0/verbs","value":["get","list","watch"]}]'

# Cap MongoDB WiredTiger cache to prevent OOMKill on 7GB nodes
kubectl patch deployment fights-db -n super-heroes --type=json -p='[
  {"op":"add","path":"/spec/template/spec/containers/0/resources","value":{"requests":{"memory":"512Mi","cpu":"100m"},"limits":{"memory":"1Gi","cpu":"500m"}}},
  {"op":"add","path":"/spec/template/spec/containers/0/args","value":["--wiredTigerCacheSizeGB","0.25"]}
]'

# Wait for fights-db to roll out, then run the Liquibase init job
kubectl rollout status deployment/fights-db -n super-heroes --timeout=120s

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

kubectl wait --for=condition=complete job/rest-fights-liquibase-mongodb-init \
  -n super-heroes --timeout=120s

kubectl rollout restart deployment/rest-fights -n super-heroes
kubectl rollout status deployment/rest-fights -n super-heroes --timeout=120s
```

> **Why these fixes are needed:**
> - **Endpoint RBAC**: `rest-fights` uses Smallrye Stork for Kubernetes-native service discovery, which watches `endpoints`. The upstream manifest's `view-jobs` Role only grants `get` on `jobs`.
> - **MongoDB memory**: The `fights-db` MongoDB image has no memory limit by default. On nodes with limited allocatable memory it is OOMKilled before it can run the init script that creates the `superfight` database user, causing `rest-fights` to fail authentication on every restart.
> - **Liquibase job**: The upstream job runs as the `rest-fights` ServiceAccount. Without the endpoint RBAC fix above, it also crashes before completing the schema migration.

### 5. Verify the cluster

```bash
# System nodes
kubectl get nodes

# Karpenter pods
kubectl get pods -n karpenter

# Karpenter NodePool and NodeClass
kubectl get nodepool
kubectl get ec2nodeclass

# Online Boutique workloads
kubectl get pods -n onlineboutique

# Super Heroes workloads
kubectl get pods -n super-heroes

# All load generators
kubectl get pods -n onlineboutique -l app=boutique-load-gen
kubectl get pods -n super-heroes -l app=superheroes-load-gen

# Node resource usage
kubectl top nodes
kubectl top pods -n onlineboutique
kubectl top pods -n super-heroes
```

### 6. Watch Karpenter scale nodes

As the load generators run, Karpenter will provision additional nodes. Watch it in real time:

```bash
# Stream Karpenter controller logs
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f

# Watch nodes appear/disappear
kubectl get nodes -w

# Watch NodeClaims (Karpenter's node lifecycle objects)
kubectl get nodeclaim -w
```

### 7. Access the applications

**Online Boutique** — default catch-all Ingress rule:

```bash
terraform output online_boutique_url
# Example: http://<lb-hostname>
```

**Quarkus Super Heroes** — routed by `Host` header. The Ingress uses `superheroes.local` as its hostname, so either:

Add to `/etc/hosts` (replace with your actual LB hostname):
```bash
# Get the LB hostname
LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

# Resolve it to an IP and add to /etc/hosts
dig +short $LB | head -1 | xargs -I{} sudo sh -c 'echo "{} superheroes.local" >> /etc/hosts'

# Then open http://superheroes.local in your browser
```

Or use curl directly with the Host header:
```bash
LB=$(kubectl get svc ingress-nginx-controller -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -H "Host: superheroes.local" http://$LB/
```

---

## Overriding Variables

```bash
terraform apply \
  -var="cluster_name=my-karpenter-cluster" \
  -var="karpenter_version=1.3.3" \
  -var="node_instance_type=m5.xlarge"
```

Or via `terraform.tfvars`:

```hcl
cluster_name       = "my-karpenter-cluster"
karpenter_version  = "1.3.3"
node_instance_type = "m5.xlarge"
```

---

## Outputs

```bash
terraform output                               # all outputs
terraform output cluster_name                  # cluster name
terraform output online_boutique_url           # Online Boutique URL
terraform output karpenter_interruption_queue  # SQS queue name
terraform output karpenter_node_role_arn       # node role ARN
terraform output karpenter_controller_role_arn # controller role ARN
```

---

## How Karpenter Works in This Setup

1. **Pending pods** trigger Karpenter when the scheduler cannot place them on existing nodes
2. Karpenter evaluates the **NodePool** requirements (arch, OS, instance family, capacity type)
3. It queries the **EC2NodeClass** to find matching subnets and security groups (via `karpenter.sh/discovery` tags)
4. A new EC2 instance is launched using the **Karpenter node IAM role** and the AL2023 AMI
5. The node registers with EKS using the **EKS Access Entry** (no `aws-auth` modification needed)
6. When pods are removed or nodes become underutilized, Karpenter **consolidates** nodes after 1 minute
7. **Spot interruption warnings** from EventBridge → SQS trigger graceful node draining before termination

---

## Tearing Down

### Using the script (recommended)

```bash
./uninstall.sh
```

See the [Quick Start](#quick-start) section for what each step does and why a plain `terraform destroy` is not sufficient.

### Manual steps

If you need to tear down without the script, follow these steps in order. A plain `terraform destroy` will fail or leave the VPC behind because ingress-nginx creates a Classic Load Balancer and security groups outside Terraform's management.

#### 1. Delete Kubernetes namespaces (triggers ELB deletion)

While the cluster is still alive, delete the namespaces so the Kubernetes cloud-controller removes the ELB via its finalizer:

```bash
aws eks update-kubeconfig --region us-west-2 --name sp-eks-karpenter
kubectl delete namespace ingress-nginx --ignore-not-found
kubectl delete namespace onlineboutique --ignore-not-found
kubectl delete namespace super-heroes --ignore-not-found
```

Wait ~60 seconds for the ELB to be deleted by the cloud-controller.

#### 2. Remove orphaned Kubernetes state entries

The Helm and Kubernetes providers cannot initialize after the EKS cluster is deleted, so those state entries must be removed before the final destroy pass:

```bash
terraform state list | grep -E '^(helm_release|kubernetes_|null_resource)\.' | \
  xargs terraform state rm
```

#### 3. Run destroy

```bash
terraform destroy -auto-approve
```

This destroys all AWS resources. If the VPC deletion fails with `DependencyViolation`, proceed to step 4.

#### 4. Delete any remaining ELBs and security groups

The ingress-nginx controller may leave behind a Classic Load Balancer and `k8s-elb-*` security groups. Find and delete them:

```bash
VPC_ID=$(aws ec2 describe-vpcs --region us-west-2 \
  --filters "Name=tag:Name,Values=sp-eks-karpenter-vpc" \
  --query 'Vpcs[0].VpcId' --output text)

# Delete ELBs
aws elb describe-load-balancers --region us-west-2 \
  --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" \
  --output text | xargs -n1 -I{} aws elb delete-load-balancer \
  --region us-west-2 --load-balancer-name {}

# Wait for ENIs to release
sleep 30

# Delete k8s-elb-* security groups
aws ec2 describe-security-groups --region us-west-2 \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=k8s-elb-*" \
  --query 'SecurityGroups[*].GroupId' --output text | \
  tr '\t' '\n' | xargs -I{} aws ec2 delete-security-group --region us-west-2 --group-id {}
```

#### 5. Final destroy

```bash
terraform destroy -auto-approve
```

> If nodes get stuck before destroy, run `kubectl delete nodeclaim --all` to force Karpenter to terminate its instances first.

---

## Cost Estimate

Running continuously in us-west-2:

| Resource | Approx cost/month |
|---|---|
| EKS control plane | ~$73 |
| 3x m5.large system nodes | ~$210 |
| Karpenter workload nodes (varies with load) | ~$50–200 |
| 3x NAT gateways | ~$99 |
| NLB (ingress-nginx) | ~$18 |
| SQS + EventBridge | ~$1 |
| **Total** | **~$450–600/month** |
