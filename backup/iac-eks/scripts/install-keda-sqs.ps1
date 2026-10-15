$ErrorActionPreference = 'Stop'

# ToggleMaster: install KEDA and scale analytics-service-app from SQS analytics-queue.
# Run from C:\posgrad\iac-eks\scripts or any location; requires AWS CLI and kubectl (no Helm).

$Region       = 'us-east-2'
$ClusterName  = 'togglemaster-eks'
$QueueName    = 'analytics-queue'
$Namespace    = 'default'       # Namespace where analytics-service-app is deployed
$Deployment   = 'analytics-service-app'
$MinReplicas  = 0               # Set to 1 if the consumer must always stay running
$MaxReplicas  = 4
$QueueLength  = 5               # Target queued messages per replica
$RoleName     = 'togglemaster-keda-sqs-role'
$PolicyName   = 'togglemaster-keda-sqs-read'
$AccountId    = (& aws sts get-caller-identity --query Account --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) { throw 'AWS CLI is not authenticated. Run aws sso login or configure your AWS credentials first.' }

$ClusterArn = "arn:aws:eks:${Region}:${AccountId}:cluster/${ClusterName}"
$QueueUrl = (& aws sqs get-queue-url --region $Region --queue-name $QueueName --query QueueUrl --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($QueueUrl)) { throw "Could not find SQS queue '$QueueName' in $Region." }
$QueueArn = (& aws sqs get-queue-attributes --region $Region --queue-url $QueueUrl --attribute-names QueueArn --query 'Attributes.QueueArn' --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($QueueArn)) { throw "Could not read ARN for SQS queue '$QueueName'." }

Write-Host "Account: $AccountId | Cluster: $ClusterName | Queue: $QueueUrl"
aws eks update-kubeconfig --region $Region --name $ClusterName
if ($LASTEXITCODE -ne 0) { throw 'Could not configure kubectl context.' }

# KEDA needs AWS permissions on its operator, not static AWS keys in a Kubernetes Secret.
$trust = @{
  Version = '2012-10-17'
  Statement = @(@{
    Effect = 'Allow'
    Principal = @{ Service = 'pods.eks.amazonaws.com' }
    Action = @('sts:AssumeRole','sts:TagSession')
    Condition = @{
      StringEquals = @{ 'aws:SourceAccount' = $AccountId }
      ArnEquals = @{ 'aws:SourceArn' = $ClusterArn }
    }
  })
} | ConvertTo-Json -Depth 10
$trustFile = Join-Path $env:TEMP 'togglemaster-keda-trust.json'
[System.IO.File]::WriteAllText($trustFile, $trust, [System.Text.UTF8Encoding]::new($false))

# Avoid probing a missing role with get-role: PowerShell can turn AWS CLI stderr into a terminating error.
$existingRoleArn = (& aws iam list-roles --query "Roles[?RoleName=='$RoleName'].Arn | [0]" --output text).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not query IAM roles. Check IAM permissions.' }
if ([string]::IsNullOrWhiteSpace($existingRoleArn) -or $existingRoleArn -eq 'None') {
  aws iam create-role --role-name $RoleName --description 'KEDA SQS scaler for ToggleMaster EKS lab' --assume-role-policy-document "file://$trustFile" | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not create KEDA IAM role. Check IAM permissions.' }
} else {
  aws iam update-assume-role-policy --role-name $RoleName --policy-document "file://$trustFile"
  if ($LASTEXITCODE -ne 0) { throw 'Could not update KEDA IAM trust policy.' }
}

$policy = @{
  Version = '2012-10-17'
  Statement = @(@{
    Effect = 'Allow'
    Action = @('sqs:GetQueueAttributes','sqs:GetQueueUrl','sqs:ReceiveMessage')
    Resource = $QueueArn
  })
} | ConvertTo-Json -Depth 8
$policyFile = Join-Path $env:TEMP 'togglemaster-keda-sqs-policy.json'
[System.IO.File]::WriteAllText($policyFile, $policy, [System.Text.UTF8Encoding]::new($false))
aws iam put-role-policy --role-name $RoleName --policy-name $PolicyName --policy-document "file://$policyFile"
if ($LASTEXITCODE -ne 0) { throw 'Could not attach inline SQS policy to KEDA role.' }

# Install KEDA directly from the official release manifest using kubectl; Helm is not required.
# KEDA 2.21.0 supports Kubernetes 1.34-1.36, including this cluster's Kubernetes 1.36.
kubectl apply --server-side -f https://github.com/kedacore/keda/releases/download/v2.21.0/keda-2.21.0.yaml
if ($LASTEXITCODE -ne 0) { throw 'KEDA manifest installation failed.' }
kubectl rollout status deployment/keda-operator -n keda --timeout=180s
if ($LASTEXITCODE -ne 0) { throw 'KEDA operator did not become ready after installation.' }

# Ensure the EKS Pod Identity Agent addon exists before creating the association.
$podIdentityAddon = (& aws eks describe-addon --region $Region --cluster-name $ClusterName --addon-name eks-pod-identity-agent --query 'addon.status' --output text 2>$null)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($podIdentityAddon | Out-String).Trim()) -or ($podIdentityAddon | Out-String).Trim() -eq 'None') {
  aws eks create-addon --region $Region --cluster-name $ClusterName --addon-name eks-pod-identity-agent --resolve-conflicts OVERWRITE | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not install EKS Pod Identity Agent addon. Check IAM permissions.' }
  aws eks wait addon-active --region $Region --cluster-name $ClusterName --addon-name eks-pod-identity-agent
  if ($LASTEXITCODE -ne 0) { throw 'EKS Pod Identity Agent addon did not become active.' }
}

$RoleArn = (& aws iam get-role --role-name $RoleName --query 'Role.Arn' --output text).Trim()
$associationsJson = & aws eks list-pod-identity-associations --region $Region --cluster-name $ClusterName --namespace keda --service-account keda-operator --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not list EKS Pod Identity associations.' }
$associations = ($associationsJson | ConvertFrom-Json).associations
if ($associations -and $associations.Count -gt 0) {
  $associationId = $associations[0].associationId
  aws eks update-pod-identity-association --region $Region --cluster-name $ClusterName --association-id $associationId --role-arn $RoleArn | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not update KEDA Pod Identity association.' }
} else {
  aws eks create-pod-identity-association --region $Region --cluster-name $ClusterName --namespace keda --service-account keda-operator --role-arn $RoleArn | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Could not create KEDA Pod Identity association. Confirm eks-pod-identity-agent is installed and your IAM permissions allow this operation.' }
}