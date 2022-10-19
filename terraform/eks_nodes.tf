data "aws_iam_policy_document" "pachaform_nodes_assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pachaform_nodes" {
  assume_role_policy = data.aws_iam_policy_document.pachaform_nodes_assume_role_policy.json
  name               = "${var.project_name}-nodes"
}

resource "aws_iam_role_policy_attachment" "pachaform_nodes_AmazonSSMManagedInstanceCore" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "pachaform_nodes_AmazonEKSWorkerNodePolicy" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform_nodes_AmazonEKS_CNI_Policy" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "pachaform_nodes_AmazonEBSCSIDriverPolicy" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role_policy_attachment" "pachaform_nodes_AmazonEC2ContainerRegistryReadOnly" {
  role       = aws_iam_role.pachaform_nodes.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "pachaform_launch_template" {
  ebs_optimized          = var.lt_ebs_optimized
  name                   = "${var.project_name}-launch-template"
  vpc_security_group_ids = [aws_security_group.pachaform_sg.id]
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

resource "aws_eks_node_group" "pachaform_nodes" {
  cluster_name    = aws_eks_cluster.pachaform_cluster.name
  node_group_name = "${var.project_name}-nodes"
  node_role_arn   = aws_iam_role.pachaform_nodes.arn
  ami_type        = "AL2_x86_64"
  labels = {
    "node_tag" = var.node_tag
  }

  subnet_ids = [
    aws_subnet.pachaform_private_subnet_1.id,
    aws_subnet.pachaform_private_subnet_2.id,
    aws_subnet.pachaform_public_subnet_1.id,
    aws_subnet.pachaform_public_subnet_2.id,
  ]
  capacity_type = var.node_capacity_type
  launch_template {
    id      = aws_launch_template.pachaform_launch_template.id
    version = aws_launch_template.pachaform_launch_template.latest_version
  }
  instance_types = var.node_instance_types

  scaling_config {
    desired_size = var.desired_nodes
    max_size     = var.max_nodes
    min_size     = var.min_nodes
  }

  depends_on = [
    aws_iam_role_policy_attachment.pachaform_nodes_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.pachaform_nodes_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.pachaform_nodes_AmazonEC2ContainerRegistryReadOnly,
    kubernetes_storage_class.gp3,
    aws_eks_cluster.pachaform_cluster,
  ]
  timeouts {
    create = var.node_timeout
    delete = var.node_timeout
    update = var.node_timeout
  }
  tags = {
    "karpenter.sh/discovery/${var.project_name}-cluster" = "${var.project_name}-cluster"
    "node_tag"                                           = "${var.node_tag}"
  }
}