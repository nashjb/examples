resource "kubectl_manifest" "karpenter_provisioner" {
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1alpha5
    kind: Provisioner
    metadata:
      name: default
    spec:
      consolidation:
        enabled: true
      requirements:
        - key: karpenter.k8s.aws/instance-family
          operator: NotIn
          values: [c5ad, c5d, c6gd, c6id, g4ad, g4dn, m5ad, m5d, m5dn, m6gd, m6id, p3dn, p4d, p4de, r5ad, r5d, r5dn, r6gd, r6id, x2gd, x2idn, x2iedn, z1d]
        # Exclude small instance sizes
        - key: karpenter.k8s.aws/instance-size
          operator: NotIn
          values: [nano, micro, small]
        - key: kubernetes.io/arch
          operator: In
          values: [amd64, arm64]
        - key: "karpenter.sh/capacity-type"
          operator: In
          values: ["spot", "on-demand"]
      providerRef:
        name: default
  YAML  

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_node_template
  ]
}

resource "kubectl_manifest" "karpenter_node_template" {
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1alpha1
    kind: AWSNodeTemplate
    metadata:
      name: default
    spec:
      amiFamily: AL2
      blockDeviceMappings:
        - deviceName: /dev/xvda
          ebs:
            volumeSize: "${var.lt_block_ebs_size}G"
            volumeType: ${var.lt_block_ebs_type}
            iops: ${var.lt_block_ebs_iops}
            encrypted: true
            deleteOnTermination: true
            throughput: ${var.lt_block_ebs_throughput}
      instanceProfile: KarpenterNodeInstanceProfile-${var.project_name}-cluster
      subnetSelector:
        karpenter.sh/discovery/${var.project_name}-cluster: ${var.project_name}-cluster
      securityGroupSelector:
        karpenter.sh/discovery/${var.project_name}-cluster: ${var.project_name}-cluster
      tags:
        karpenter.sh/discovery/${var.project_name}-cluster: ${var.project_name}-cluster
  YAML  

  depends_on = [
    helm_release.karpenter,
  ]
}


resource "aws_iam_instance_profile" "karpenter" {
  name = "KarpenterNodeInstanceProfile-${aws_eks_cluster.pachaform_cluster.name}"
  role = aws_iam_role.pachaform_nodes.name
}

data "aws_iam_policy_document" "karpenter_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringLike"
      variable = "${aws_iam_openid_connect_provider.eks.url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "${aws_iam_openid_connect_provider.eks.url}:sub"
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }

    principals {
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
      type        = "Federated"
    }
  }
}

resource "aws_iam_policy" "karpenter_policy" {
  name = "${var.project_name}-karpenter-policy"
  policy = jsonencode(
    {
      "Statement" : [
        {
          "Action" : [
            "ssm:GetParameter",
            "iam:PassRole",
            "ec2:RunInstances",
            "ec2:DescribeSubnets",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeLaunchTemplates",
            "ec2:DescribeInstances",
            "ec2:DescribeInstanceTypes",
            "ec2:DescribeInstanceTypeOfferings",
            "ec2:DescribeAvailabilityZones",
            "ec2:DeleteLaunchTemplate",
            "ec2:CreateTags",
            "ec2:CreateLaunchTemplate",
            "ec2:CreateFleet",
            "ec2:DescribeSpotPriceHistory",
            "pricing:GetProducts"
          ],
          "Effect" : "Allow",
          "Resource" : "*",
          "Sid" : "Karpenter"
        },
        {
          "Action" : "ec2:TerminateInstances",
          "Condition" : {
            "StringLike" : {
              "ec2:ResourceTag/Name" : "*karpenter*"
            }
          },
          "Effect" : "Allow",
          "Resource" : "*",
          "Sid" : "ConditionalEC2Termination"
        }
      ],
      "Version" : "2012-10-17"
    }
  )
}

resource "aws_iam_role" "pachaform_karpenter_role" {
  name               = "KarpenterControllerRole-${aws_eks_cluster.pachaform_cluster.name}"
  assume_role_policy = data.aws_iam_policy_document.karpenter_assume_role_policy.json
}

resource "aws_iam_role_policy_attachment" "karpenter_policy_attachment" {
  role       = aws_iam_role.pachaform_karpenter_role.id
  policy_arn = aws_iam_policy.karpenter_policy.arn
}

resource "aws_iam_role_policy_attachment" "karpenter_node_policy_attachment" {
  role       = aws_iam_role.pachaform_nodes.id
  policy_arn = aws_iam_policy.karpenter_policy.arn
}

resource "aws_iam_role_policy_attachment" "pachaform_karpenter_AmazonSSMManagedInstanceCore" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "pachaform_karpenter_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.pachaform_karpenter_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform_karpenter_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.pachaform_karpenter_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "pachaform_karpenter_AmazonEBSCSIDriverPolicy" {
  role       = aws_iam_role.pachaform_karpenter_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform_karpenter_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.pachaform_karpenter_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true

  name       = "karpenter"
  repository = "https://charts.karpenter.sh"
  chart      = "karpenter"
  version    = "v0.16.2"

  values = [
    templatefile("${path.module}/karpenter-values.yaml.tftpl", {
      CLUSTER_NAME             = aws_eks_cluster.pachaform_cluster.name,
      CLUSTER_ENDPOINT         = aws_eks_cluster.pachaform_cluster.endpoint,
      DEFAULT_INSTANCE_PROFILE = aws_iam_instance_profile.karpenter.name,
      SERVICE_ACCOUNT_ROLE_ARN = aws_iam_role.pachaform_karpenter_role.arn,
      SERVICE_ACCOUNT_CREATE   = var.karpenter_service_account_create,
      SERVICE_ACCOUNT_NAME     = var.karpenter_service_account_name,
    })
  ]
  depends_on = [
    aws_eks_node_group.pachaform_nodes,
    aws_eks_addon.pachaform_ebs_driver,
    aws_eks_addon.pachaform_cni,
    aws_eks_addon.pachaform_kube_proxy,
    aws_eks_addon.pachaform_coredns
  ]
}