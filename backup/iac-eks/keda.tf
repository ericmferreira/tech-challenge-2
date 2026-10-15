# KEDA installation and SQS permissions for the Analytics scaler.
# Requires hashicorp/helm provider and the EKS Pod Identity Agent add-on.

resource "aws_iam_role" "keda_sqs" {
  name = "${local.name}-keda-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })
}

resource "aws_iam_role_policy" "keda_sqs" {
  name = "${local.name}-keda-sqs-read-queue"
  role = aws_iam_role.keda_sqs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl"
      ]
      Resource = "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:analytics-queue"
    }]
  })
}

# The association can be created before the ServiceAccount exists. The chart
# creates keda/keda-operator, and this dependency ensures the IAM association
# exists before the KEDA operator pods are installed.
resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda_sqs.arn

  depends_on = [module.eks]
}

resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  namespace        = "keda"
  create_namespace = true
  wait             = true
  timeout          = 600

  depends_on = [
    aws_iam_role_policy.keda_sqs,
    aws_eks_pod_identity_association.keda_operator
  ]
}
