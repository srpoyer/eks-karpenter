locals {
  oidc_provider = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")

  # EventBridge rules for Karpenter interruption handling
  interruption_events = {
    spot_interruption = {
      name        = "spot-interruption"
      source      = "aws.ec2"
      detail_type = "EC2 Spot Instance Interruption Warning"
    }
    instance_rebalance = {
      name        = "instance-rebalance"
      source      = "aws.ec2"
      detail_type = "EC2 Instance Rebalance Recommendation"
    }
    instance_state_change = {
      name        = "instance-state-change"
      source      = "aws.ec2"
      detail_type = "EC2 Instance State-change Notification"
    }
    scheduled_change = {
      name        = "scheduled-change"
      source      = "aws.health"
      detail_type = "AWS Health Event"
    }
  }
}

# ── SQS Interruption Queue ────────────────────────────────────────────────────
# Karpenter watches this queue to gracefully drain nodes before spot termination

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-interruption"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.url

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption.arn
    }]
  })
}

# ── EventBridge Rules ─────────────────────────────────────────────────────────

resource "aws_cloudwatch_event_rule" "karpenter_interruption" {
  for_each = local.interruption_events

  name        = "${var.cluster_name}-karpenter-${each.value.name}"
  description = "Karpenter: ${each.value.detail_type}"

  event_pattern = jsonencode({
    source      = [each.value.source]
    detail-type = [each.value.detail_type]
  })
}

resource "aws_cloudwatch_event_target" "karpenter_interruption" {
  for_each = local.interruption_events

  rule      = aws_cloudwatch_event_rule.karpenter_interruption[each.key].name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ── IAM: Karpenter Node Role ──────────────────────────────────────────────────
# Attached to EC2 instances that Karpenter provisions

resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_node_worker" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_cni" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ecr" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "karpenter_node_ssm" {
  role       = aws_iam_role.karpenter_node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name
}

# EKS Access Entry — allows Karpenter-provisioned nodes to join the cluster
# without needing to modify aws-auth ConfigMap
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"
}

# ── IAM: Karpenter Controller Role (IRSA) ────────────────────────────────────

resource "aws_iam_role" "karpenter_controller" {
  name = "${var.cluster_name}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_provider}:aud" = "sts.amazonaws.com"
          "${local.oidc_provider}:sub" = "system:serviceaccount:karpenter:karpenter"
        }
      }
    }]
  })
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Karpenter controller permissions"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowScopedEC2InstanceActions"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*::image/*",
          "arn:aws:ec2:*::snapshot/*",
          "arn:aws:ec2:*:*:security-group/*",
          "arn:aws:ec2:*:*:subnet/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet"]
      },
      {
        Sid      = "AllowScopedEC2LaunchTemplateActions"
        Effect   = "Allow"
        Resource = "arn:aws:ec2:*:*:launch-template/*"
        Action   = ["ec2:RunInstances", "ec2:CreateFleet"]
      },
      {
        Sid    = "AllowScopedEC2InstanceActionsWithTags"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*:*:fleet/*",
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:launch-template/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
        ]
        Action = ["ec2:RunInstances", "ec2:CreateFleet", "ec2:CreateLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedResourceCreationTagging"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*:*:fleet/*",
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:volume/*",
          "arn:aws:ec2:*:*:network-interface/*",
          "arn:aws:ec2:*:*:launch-template/*",
          "arn:aws:ec2:*:*:spot-instances-request/*",
        ]
        Action = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "ec2:CreateAction" = ["RunInstances", "CreateFleet", "CreateLaunchTemplate"]
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:RequestTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedResourceTagging"
        Effect   = "Allow"
        Resource = "arn:aws:ec2:*:*:instance/*"
        Action   = "ec2:CreateTags"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
          "ForAllValues:StringEquals" = {
            "aws:TagKeys" = ["karpenter.sh/nodeclaim", "Name"]
          }
        }
      },
      {
        Sid    = "AllowScopedDeletion"
        Effect = "Allow"
        Resource = [
          "arn:aws:ec2:*:*:instance/*",
          "arn:aws:ec2:*:*:launch-template/*",
        ]
        Action = ["ec2:TerminateInstances", "ec2:DeleteLaunchTemplate"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
          StringLike = {
            "aws:ResourceTag/karpenter.sh/nodepool" = "*"
          }
        }
      },
      {
        Sid      = "AllowRegionalReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action = [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory",
          "ec2:DescribeSubnets",
        ]
      },
      {
        Sid      = "AllowSSMReadActions"
        Effect   = "Allow"
        Resource = "arn:aws:ssm:*::parameter/aws/service/*"
        Action   = "ssm:GetParameter"
      },
      {
        Sid      = "AllowPricingReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "pricing:GetProducts"
      },
      {
        Sid      = "AllowInterruptionQueueActions"
        Effect   = "Allow"
        Resource = aws_sqs_queue.karpenter_interruption.arn
        Action = [
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ReceiveMessage",
        ]
      },
      {
        Sid      = "AllowPassingInstanceRole"
        Effect   = "Allow"
        Resource = aws_iam_role.karpenter_node.arn
        Action   = "iam:PassRole"
      },
      {
        Sid      = "AllowScopedInstanceProfileCreationActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = ["iam:CreateInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowScopedInstanceProfileTagActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = ["iam:TagInstanceProfile"]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
            "aws:RequestTag/kubernetes.io/cluster/${var.cluster_name}"  = "owned"
            "aws:RequestTag/topology.kubernetes.io/region"              = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
            "aws:RequestTag/karpenter.k8s.aws/ec2nodeclass"  = "*"
          }
        }
      },
      {
        Sid    = "AllowScopedInstanceProfileActions"
        Effect = "Allow"
        Resource = "*"
        Action = [
          "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile",
        ]
        Condition = {
          StringEquals = {
            "aws:ResourceTag/kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "aws:ResourceTag/topology.kubernetes.io/region"             = var.region
          }
          StringLike = {
            "aws:ResourceTag/karpenter.k8s.aws/ec2nodeclass" = "*"
          }
        }
      },
      {
        Sid      = "AllowInstanceProfileReadActions"
        Effect   = "Allow"
        Resource = "*"
        Action   = "iam:GetInstanceProfile"
      },
      {
        Sid      = "AllowAPIServerEndpointDiscovery"
        Effect   = "Allow"
        Resource = aws_eks_cluster.main.arn
        Action   = "eks:DescribeCluster"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

# ── Discovery Tags ────────────────────────────────────────────────────────────
# Karpenter uses these tags to discover which subnets and security groups
# to use when launching new nodes.

resource "aws_ec2_tag" "private_subnet_karpenter" {
  count       = 3
  resource_id = aws_subnet.private[count.index].id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# Tag the EKS-managed cluster primary security group (auto-created by EKS,
# already allows all intra-cluster communication)
resource "aws_ec2_tag" "cluster_primary_sg_karpenter" {
  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = "karpenter.sh/discovery"
  value       = var.cluster_name
}

# ── Karpenter Helm Release ────────────────────────────────────────────────────

resource "helm_release" "karpenter" {
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  namespace        = "karpenter"
  create_namespace = true
  wait             = true
  timeout          = 300

  values = [yamlencode({
    settings = {
      clusterName       = aws_eks_cluster.main.name
      interruptionQueue = aws_sqs_queue.karpenter_interruption.name
    }
    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
      }
    }
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.karpenter_controller,
    aws_eks_access_entry.karpenter_node,
    aws_iam_openid_connect_provider.eks,
    aws_ec2_tag.private_subnet_karpenter,
    aws_ec2_tag.cluster_primary_sg_karpenter,
    aws_eks_access_policy_association.admin_user,
  ]
}

# ── EC2NodeClass ──────────────────────────────────────────────────────────────
# Defines the AWS-specific configuration for nodes Karpenter provisions:
# AMI family, IAM role, subnets, and security groups.

resource "null_resource" "karpenter_node_class" {
  triggers = {
    cluster_name = var.cluster_name
    node_role    = aws_iam_role.karpenter_node.name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: karpenter.k8s.aws/v1
      kind: EC2NodeClass
      metadata:
        name: default
      spec:
        amiSelectorTerms:
          - alias: al2023@latest
        role: ${aws_iam_role.karpenter_node.name}
        subnetSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${var.cluster_name}
        securityGroupSelectorTerms:
          - tags:
              karpenter.sh/discovery: ${var.cluster_name}
      EOF
    EOT
  }

  depends_on = [
    helm_release.karpenter,
    null_resource.update_kubeconfig,
  ]
}

# ── NodePool ──────────────────────────────────────────────────────────────────
# Defines the constraints for nodes Karpenter can provision.
# Allows on-demand and spot across c/m/r instance families (gen 3+).
# Consolidates underutilized or empty nodes after 1 minute.

resource "null_resource" "karpenter_node_pool" {
  triggers = {
    cluster_name = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      kubectl apply -f - <<EOF
      apiVersion: karpenter.sh/v1
      kind: NodePool
      metadata:
        name: default
      spec:
        template:
          spec:
            nodeClassRef:
              group: karpenter.k8s.aws
              kind: EC2NodeClass
              name: default
            requirements:
              - key: kubernetes.io/arch
                operator: In
                values: ["amd64"]
              - key: kubernetes.io/os
                operator: In
                values: ["linux"]
              - key: karpenter.sh/capacity-type
                operator: In
                values: ["on-demand", "spot"]
              - key: node.kubernetes.io/instance-category
                operator: In
                values: ["c", "m", "r"]
              - key: node.kubernetes.io/instance-generation
                operator: Gt
                values: ["2"]
        limits:
          cpu: "1000"
          memory: 1000Gi
        disruption:
          consolidationPolicy: WhenEmptyOrUnderutilized
          consolidateAfter: 1m
      EOF
    EOT
  }

  depends_on = [null_resource.karpenter_node_class]
}
