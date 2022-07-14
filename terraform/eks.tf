resource "aws_iam_role" "pachaform-cluster" {
  name               = "${var.project_name}-cluster"
  assume_role_policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
      {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "pachaform-AmazonEKSClusterPolicy" {
  role       = aws_iam_role.pachaform-cluster.id
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "pachaform-cluster" {
  name     = "${var.project_name}-cluster"
  role_arn = aws_iam_role.pachaform-cluster.arn
  vpc_config {
    subnet_ids = [
      aws_subnet.pachaform_private_subnet_1.id,
      aws_subnet.pachaform_private_subnet_2.id,
      aws_subnet.pachaform_public_subnet_1.id,
      aws_subnet.pachaform_public_subnet_2.id,
    ]
  }
  depends_on = [
    aws_iam_role_policy_attachment.pachaform-AmazonEKSClusterPolicy,
    aws_internet_gateway.pachaform_internet_gateway,
    aws_nat_gateway.pachaform_nat_gateway,
    aws_security_group.pachaform_sg,
    aws_route.pachaform_private_route,
    aws_route.pachaform_public_route,
    aws_route_table_association.pachaform_private_rta_1,
    aws_route_table_association.pachaform_private_rta_2,
    aws_db_instance.pachaform-postgres,
  ]
}

data "aws_iam_policy_document" "pachaform-nodes-assume-role-policy" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pachaform-nodes" {
  assume_role_policy = data.aws_iam_policy_document.pachaform-nodes-assume-role-policy.json
  name               = "${var.project_name}-nodes"
}

resource "aws_iam_role_policy_attachment" "pachaform-nodes-AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.pachaform-nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform-nodes-AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.pachaform-nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "pachaform-nodes-AmazonEBSCSIDriverPolicy" {
  role       = aws_iam_role.pachaform-nodes.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform-nodes-AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.pachaform-nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "pachaform-nodes-launch-template" {
  ebs_optimized = var.lt_ebs_optimized
  name          = "${var.project_name}-nodes-launch-template"
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      delete_on_termination = "true"
      volume_size           = var.lt_block_ebs_size
      volume_type           = var.lt_block_ebs_type
      iops                  = var.lt_block_ebs_iops
      throughput            = var.lt_block_ebs_throughput
    }
  }
}

resource "aws_eks_node_group" "pachaform-nodes" {
  cluster_name    = aws_eks_cluster.pachaform-cluster.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.pachaform-nodes.arn
  ami_type        = "AL2_x86_64"

  subnet_ids = [
    aws_subnet.pachaform_private_subnet_1.id,
    aws_subnet.pachaform_private_subnet_2.id,
    aws_subnet.pachaform_public_subnet_1.id,
    aws_subnet.pachaform_public_subnet_2.id
  ]
  capacity_type = var.node_capacity_type
  launch_template {
    id      = aws_launch_template.pachaform-nodes-launch-template.id
    version = aws_launch_template.pachaform-nodes-launch-template.latest_version
  }
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.desired_nodes
    max_size     = var.max_nodes
    min_size     = var.min_nodes
  }

  depends_on = [
    aws_iam_role_policy_attachment.pachaform-nodes-AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.pachaform-nodes-AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.pachaform-nodes-AmazonEC2ContainerRegistryReadOnly,
    kubernetes_storage_class.gp3,
    aws_launch_template.pachaform-nodes-launch-template,
    aws_eks_cluster.pachaform-cluster,
  ]
  timeouts {
    create = var.node_timeout
    delete = var.node_timeout
    update = var.node_timeout
  }
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.pachaform-cluster.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.pachaform-cluster.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
}

resource "aws_eks_addon" "pachaform-cni" {
  cluster_name = aws_eks_cluster.pachaform-cluster.name
  addon_name   = "vpc-cni"
  tags = {
    Name = "${var.project_name}-vpc-cni"
  }
}

resource "aws_eks_addon" "pachaform-ebs-driver" {
  cluster_name = aws_eks_cluster.pachaform-cluster.name
  addon_name   = "aws-ebs-csi-driver"
  tags = {
    Name = "${var.project_name}-ebs-driver"
  }
  depends_on = [
    aws_eks_cluster.pachaform-cluster,
    aws_eks_node_group.pachaform-nodes,
  ]
}

resource "aws_eks_addon" "pachaform-kube-proxy" {
  cluster_name = aws_eks_cluster.pachaform-cluster.name
  addon_name   = "kube-proxy"
  tags = {
    Name = "${var.project_name}-kube-proxy"
  }
}

resource "aws_eks_addon" "pachaform-coredns" {
  cluster_name = aws_eks_cluster.pachaform-cluster.name
  addon_name   = "coredns"
  tags = {
    Name = "${var.project_name}-coredns"
  }
  depends_on = [
    aws_eks_cluster.pachaform-cluster,
    aws_eks_node_group.pachaform-nodes,
  ]
}

