# IAM for EKS workloads is managed here. No static AWS keys are stored in Kubernetes Secrets.
# EKS Pod Identity Agent is enabled in module.eks.cluster_addons.

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    sid     = "AllowOnlyThisEKSCluster"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values = [
        "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${local.name}-eks"
      ]
    }
  }
}

# The KEDA operator can read SQS queue metrics. It cannot consume/delete messages
# or write to DynamoDB; those permissions belong to the Analytics workload.
resource "aws_iam_role" "keda_sqs" {
  name               = "${local.name}-eks-keda-metrics-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  description        = "KEDA operator: read metrics from ToggleMaster analytics SQS queue."
}

resource "aws_iam_role_policy" "keda_sqs" {
  name = "${local.name}-keda-read-analytics-queue"
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

resource "aws_eks_pod_identity_association" "keda_operator" {
  cluster_name    = module.eks.cluster_name
  namespace       = "keda"
  service_account = "keda-operator"
  role_arn        = aws_iam_role.keda_sqs.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy.keda_sqs
  ]
}

# Evaluation Service is a producer: it may only enqueue evaluation events.
resource "aws_iam_role" "evaluation_service" {
  name               = "${local.name}-eks-evaluation-sqs-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  description        = "Evaluation Service: send events to ToggleMaster analytics SQS queue."
}

resource "aws_iam_role_policy" "evaluation_service" {
  name = "${local.name}-evaluation-send-analytics-events"
  role = aws_iam_role.evaluation_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:analytics-queue"
    }]
  })
}

resource "aws_eks_pod_identity_association" "evaluation_service" {
  cluster_name    = module.eks.cluster_name
  namespace       = "togglemaster"
  service_account = "evaluation-service"
  role_arn        = aws_iam_role.evaluation_service.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy.evaluation_service
  ]
}

# Analytics Service consumes events and writes the resulting items to DynamoDB.
resource "aws_iam_role" "analytics_service" {
  name               = "${local.name}-eks-analytics-data-role"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  description        = "Analytics Service: consume ToggleMaster SQS events and write analytics to DynamoDB."
}

resource "aws_iam_role_policy" "analytics_service" {
  name = "${local.name}-analytics-sqs-dynamodb"
  role = aws_iam_role.analytics_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ConsumeAnalyticsQueue"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl"
        ]
        Resource = "arn:aws:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:analytics-queue"
      },
      {
        Sid      = "WriteAnalyticsItems"
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/ToggleMasterAnalytics"
      }
    ]
  })
}

resource "aws_eks_pod_identity_association" "analytics_service" {
  cluster_name    = module.eks.cluster_name
  namespace       = "togglemaster"
  service_account = "analytics-service"
  role_arn        = aws_iam_role.analytics_service.arn

  depends_on = [
    module.eks,
    aws_iam_role_policy.analytics_service
  ]
}

# KEDA and Metrics Server are managed by Terraform's Helm provider.
# helm.exe is not required on the workstation; Terraform uses the Helm provider API.
resource "helm_release" "keda" {
  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.21.0"
  namespace        = "keda"
  create_namespace = true
  atomic           = true
  wait             = true
  timeout          = 600

  # The AWS Load Balancer Controller installs a Service admission webhook.
  # Its webhook Service must have ready endpoints before KEDA creates its Services,
  # otherwise the API server rejects KEDA resources with "no endpoints available".
  depends_on = [
    helm_release.load_balancer_controller,
    aws_iam_role_policy.keda_sqs,
    aws_eks_pod_identity_association.keda_operator
  ]
}
