locals {
  lbc_name      = "aws-load-balancer-controller"
  lbc_namespace = "kube-system"
  lbc_oidc_url  = trimprefix(module.eks.oidc_provider, "https://")
}

resource "aws_iam_policy" "load_balancer_controller" {
  name        = "AWSLoadBalancerControllerIAMPolicy"
  description = "IAM permissions for AWS Load Balancer Controller"

  policy = file(
    "${path.module}/policies/aws-load-balancer-controller-iam-policy.json"
  )
}

data "aws_iam_policy_document" "lbc_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.lbc_oidc_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.lbc_oidc_url}:sub"
      values   = [
        "system:serviceaccount:${local.lbc_namespace}:${local.lbc_name}"
      ]
    }
  }
}

resource "aws_iam_role" "load_balancer_controller" {
  name               = "AmazonEKSLoadBalancerControllerRole"
  assume_role_policy = data.aws_iam_policy_document.lbc_trust.json
}

resource "aws_iam_role_policy_attachment" "load_balancer_controller" {
  role       = aws_iam_role.load_balancer_controller.name
  policy_arn = aws_iam_policy.load_balancer_controller.arn
}

resource "helm_release" "load_balancer_controller" {
  name       = local.lbc_name
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.0"
  namespace  = local.lbc_namespace

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      clusterName  = module.eks.cluster_name
      region       = var.aws_region
      vpcId        = module.vpc.vpc_id
      replicaCount = 1

      serviceAccount = {
        create = true
        name   = local.lbc_name

        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.load_balancer_controller.arn
        }
      }
    })
  ]

  depends_on = [
    aws_iam_role_policy_attachment.load_balancer_controller
  ]
}