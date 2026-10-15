data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  name = var.project_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  app_services = toset([
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service"
  ])
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${local.name}-vpc"
  cidr = "10.40.0.0/16"

  azs             = local.azs
  public_subnets  = ["10.40.1.0/24", "10.40.2.0/24"]
  private_subnets = []

  create_igw              = true
  enable_nat_gateway      = false
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  tags = {
    "kubernetes.io/cluster/${local.name}-eks" = "shared"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.1"

  cluster_name    = "${local.name}-eks"
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_public_access       = true
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access_cidrs = [var.admin_cidr]

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  eks_managed_node_groups = {
    lab = {
      name           = "${local.name}-worker"
      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      # Two workers provide enough allocatable CPU for the application replicas,
      # PostgreSQL/Redis, and cluster add-ons. One m7i-flex.large was at 88% CPU
      # requests before all workloads had stabilized.
      min_size     = 2
      max_size     = 2
      desired_size = 2

      subnet_ids = module.vpc.public_subnets
      disk_size  = var.node_disk_size

      labels = {
        workload = "lab"
      }
    }
  }

  tags = {
    Project = var.project_name
  }
}

# EBS CSI Driver: required by the existing PostgreSQL PVCs.
resource "aws_iam_role" "ebs_csi" {
  name = "${local.name}-eks-ebs-csi-role"

  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  # EKS Pod Identity association needs the cluster and its Pod Identity Agent.
  depends_on = [module.eks]
}

data "aws_eks_addon_version" "ebs_csi" {
  addon_name         = "aws-ebs-csi-driver"
  kubernetes_version = var.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "aws-ebs-csi-driver"
  addon_version = data.aws_eks_addon_version.ebs_csi.version

  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi,
    aws_eks_pod_identity_association.ebs_csi
  ]
}

resource "aws_ecr_repository" "service" {
  for_each = local.app_services

  name                 = "${local.name}/${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  # Repeated publishes update the mutable :latest tag and leave prior digests untagged.
  # Expire those untagged images after one day to keep this disposable lab's ECR storage bounded.
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after one day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the latest 10 tagged lab images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["lab-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}
