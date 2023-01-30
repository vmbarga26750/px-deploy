variable "eks_nodes" {
	description = "number of worker nodes"
	type 		= number
}

variable "eksclusters" {
	description = "map of clusternumber & aws_type"
	type 		= map
}

resource "aws_vpc_dhcp_options" "dhcpopt" {
  domain_name          = format("%s.compute.internal",var.aws_region)
  domain_name_servers  = ["AmazonProvidedDNS"]
  tags = {
    Name = format("%s-%s-%s",var.name_prefix,var.config_name,"dhcp_opt")
    px-deploy_name = var.config_name
    px-deploy_username = var.PXDUSER
  }
}

resource "aws_vpc_dhcp_options_association" "dns_resolver" {
  vpc_id          = aws_vpc.vpc.id
  dhcp_options_id = aws_vpc_dhcp_options.dhcpopt.id
}

resource "aws_eip" "nat_gateway" {
  vpc = true
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "natgw" {
  allocation_id = aws_eip.nat_gateway.id
  subnet_id     = aws_subnet.subnet[0].id

  tags = {
        Name = format("%s-%s-%s",var.name_prefix,var.config_name,"ngw")
        px-deploy_name = var.config_name
	px-deploy_username = var.PXDUSER
  }
  depends_on = [aws_internet_gateway.igw]
}


resource "aws_subnet" "eks_private" {
  count	= var.clusters
  vpc_id = aws_vpc.vpc.id
  availability_zone = data.aws_availability_zones.available.names[1]
  cidr_block = "192.168.${count.index + 151}.0/24"
  tags = {
    Name = format("%s-%s-eks-private-subnet-%s",var.name_prefix,var.config_name, count.index + 1)
    px-deploy_name = var.config_name
    px-deploy_username = var.PXDUSER
    "kubernetes.io/role/internal-elb" = 1
  }
}

resource "aws_route_table" "rt_sn_private" {
  count	= var.clusters        
  vpc_id  = aws_vpc.vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.natgw.id
  }

  tags = {
    Name = format("%s-%s-eks-private-rt-%s",var.name_prefix,var.config_name, count.index + 1)
    px-deploy_name = var.config_name
    px-deploy_username = var.PXDUSER
  }
}

resource "aws_route_table_association" "rta_private" {
    count               = var.clusters
    subnet_id           = aws_subnet.eks_private[count.index].id
    route_table_id      = aws_route_table.rt_sn_private[count.index].id
}

resource "aws_iam_role" "eks-iam-role" {
  name = format("%s-%s-eks-iam",var.name_prefix,var.config_name)
  path = "/"
  assume_role_policy = jsonencode({
    Statement: [{
     Action = "sts:AssumeRole"
     Effect = "Allow"
     Principal = {
       Service = "eks.amazonaws.com"
     }
   }]
   Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role    = aws_iam_role.eks-iam-role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly-EKS" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role    = aws_iam_role.eks-iam-role.name
}

resource "aws_iam_role" "node-iam-role" {
  name = format("%s-%s-eks-nodegroup",var.name_prefix,var.config_name)

  assume_role_policy = jsonencode({
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
    Version = "2012-10-17"
  })
}

resource "aws_iam_role_policy_attachment" "AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node-iam-role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node-iam-role.name
}

resource "aws_iam_role_policy_attachment" "AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node-iam-role.name
}

resource "aws_iam_policy" "px-policy" {
  name = format("px-policy-%s-%s",var.name_prefix,var.config_name)
  description = "portworx node policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
            Sid = "" 
            Effect = "Allow"
            Action = [
                "ec2:AttachVolume",
                "ec2:ModifyVolume",
                "ec2:DetachVolume",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:DeleteTags",
                "ec2:DeleteVolume",
                "ec2:DescribeTags",
                "ec2:DescribeVolumeAttribute",
                "ec2:DescribeVolumesModifications",
                "ec2:DescribeVolumeStatus",
                "ec2:DescribeVolumes",
                "ec2:DescribeInstances",
                "autoscaling:DescribeAutoScalingGroups"
            ]
            Resource = "*"
        }]
  })
}

resource "aws_iam_role_policy_attachment" "px-pol-attach" {
  role       = aws_iam_role.node-iam-role.name
  policy_arn = aws_iam_policy.px-policy.arn
}


resource "aws_eks_cluster" "eks" {
  for_each = var.eksclusters
  name = format("%s-%s-%s",var.name_prefix,var.config_name, each.key)
  version = "1.23"
  role_arn = aws_iam_role.eks-iam-role.arn
  vpc_config {
    subnet_ids = [aws_subnet.eks_private[each.key - 1].id, aws_subnet.subnet[each.key - 1].id]
  }    

  depends_on = [
    aws_iam_role.eks-iam-role,
    aws_iam_role_policy_attachment.AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly-EKS,
  ]
  tags = {
    Name = format("%s-%s-%s",var.name_prefix,var.config_name, each.key)
    px-deploy_name = var.config_name
    px-deploy_username = var.PXDUSER
  }
}

resource "aws_eks_node_group" "worker-node-group" {
  for_each = var.eksclusters
  cluster_name  = aws_eks_cluster.eks[each.key].name
  node_group_name = format("%s-%s-%s",var.name_prefix,var.config_name, each.key)
  node_role_arn  = aws_iam_role.node-iam-role.arn
  subnet_ids   = [aws_subnet.eks_private[each.key - 1].id, aws_subnet.subnet[each.key - 1].id]
   
  launch_template {
    id      = data.aws_launch_template.cluster[each.key].id
    version = data.aws_launch_template.cluster[each.key].latest_version
  }
  
  scaling_config {
   desired_size = 3
   max_size   = 3
   min_size   = 3
  }
 
  depends_on = [
   aws_iam_role_policy_attachment.AmazonEKSWorkerNodePolicy,
   aws_iam_role_policy_attachment.AmazonEKS_CNI_Policy,
   aws_iam_role_policy_attachment.AmazonEC2ContainerRegistryReadOnly,
  ]
  tags = {
    Name = format("%s-%s-%s",var.name_prefix,var.config_name, each.key)
    px-deploy_name = var.config_name
    px-deploy_username = var.PXDUSER
  }
 }

data "aws_launch_template" "cluster" {
  for_each = var.eksclusters
  name = aws_launch_template.cluster[each.key].name
  depends_on = [aws_launch_template.cluster[each.key]]
}

resource "aws_launch_template" "cluster" {
  for_each = var.eksclusters
  name = format("%s-%s-%s",var.name_prefix,var.config_name, each.key)
  instance_type = each.value
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 50
      volume_type = "gp2"
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = format("%s-%s-%s-node",var.name_prefix,var.config_name, each.key)
    }
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = format("%s-%s-%s-node",var.name_prefix,var.config_name, each.key)
    }
  }
}
