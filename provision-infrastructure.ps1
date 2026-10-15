[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminCidr
)

$ErrorActionPreference = "Stop"

# One entry point for both existing Terraform states. No local Helm binary is required.
$ProjectRoot  = $PSScriptRoot
$Requirements  = Join-Path $ProjectRoot "iac-req"
$EksTerraform  = Join-Path $ProjectRoot "iac-eks"
$StorageClass  = Join-Path $ProjectRoot "eks\storageclass-gp3.yaml"
$AdminCidrFile = Join-Path $ProjectRoot ".togglemaster-admin-cidr"
$Region        = "us-east-2"
$ClusterName   = "togglemaster-eks"
$ExpectedAccountId = "870737143013"

foreach ($Tool in @("aws", "terraform", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$Tool' was not found in PATH."
    }
}

$AccountId = (& aws sts get-caller-identity --query Account --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) {
    throw "AWS CLI is not authenticated. Run 'aws sso login' or authenticate your configured AWS profile."
}
if ($AccountId -ne $ExpectedAccountId) {
    throw "AWS identity mismatch. This project is configured for account $ExpectedAccountId, but the current session is $AccountId."
}

if ([string]::IsNullOrWhiteSpace($AdminCidr)) {
    try {
        $PublicIp = (Invoke-RestMethod -Uri "https://checkip.amazonaws.com" -TimeoutSec 15).ToString().Trim()
    }
    catch {
        throw "Could not detect your public IPv4 address. Retry with -AdminCidr 'YOUR_PUBLIC_IP/32'."
    }

    if ($PublicIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        throw "The public IP lookup did not return an IPv4 address: '$PublicIp'."
    }

    $AdminCidr = "$PublicIp/32"
}

if ($AdminCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "AdminCidr must be an IPv4 CIDR, for example 203.0.113.10/32."
}

# Persist the exact value needed by terraform destroy. It contains no credentials.
Set-Content -LiteralPath $AdminCidrFile -Value $AdminCidr -Encoding ascii -NoNewline

Write-Host ""
Write-Host "ToggleMaster infrastructure bootstrap" -ForegroundColor Cyan
Write-Host "AWS account : $AccountId"
Write-Host "Region      : $Region"
Write-Host "EKS cluster : $ClusterName"
Write-Host "API CIDR    : $AdminCidr"
Write-Host ""

function Invoke-Terraform {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$UseEksVariables
    )

    Write-Host "`n== $Description ==" -ForegroundColor Yellow
    if ($Arguments.Count -gt 0 -and $Arguments[0] -eq "init") {
        & terraform "-chdir=$Directory" fmt -recursive
        if ($LASTEXITCODE -ne 0) {
            throw "terraform fmt failed in $Directory."
        }
    }
    $TerraformArguments = @("-chdir=$Directory") + $Arguments

    if ($UseEksVariables) {
        $TerraformArguments += @(
            "-var=aws_region=$Region",
            "-var=admin_cidr=$AdminCidr"
        )
    }

    & terraform @TerraformArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (terraform exit code $LASTEXITCODE). Fix this error before continuing."
    }
}

# Validate both existing Terraform roots before any AWS resource is created or changed.
Invoke-Terraform -Directory $Requirements -Arguments @("init", "-input=false") -Description "Initialize SQS/DynamoDB Terraform"
Invoke-Terraform -Directory $Requirements -Arguments @("validate") -Description "Validate SQS/DynamoDB Terraform"
Invoke-Terraform -Directory $EksTerraform -Arguments @("init", "-input=false") -Description "Initialize EKS Terraform"
Invoke-Terraform -Directory $EksTerraform -Arguments @("validate") -Description "Validate EKS Terraform"

# Guard against losing a local state file while AWS resources still exist. Applying an
# empty state over an already-created cluster/queue/table can lead to name collisions or
# orphaned resources. This check is read-only and happens before any Terraform apply.
$EksStateFile = Join-Path $EksTerraform "terraform.tfstate"
if (Test-Path -LiteralPath $EksStateFile) {
    $EksStateResources = & terraform "-chdir=$EksTerraform" state list
    if ($LASTEXITCODE -ne 0) { throw "Could not read iac-eks Terraform state. No resources were applied." }
    $EksStateText = ($EksStateResources | Out-String)
}
else {
    $EksStateText = ""
}
$ClusterNames = & aws eks list-clusters --region $Region --query "clusters" --output json
if ($LASTEXITCODE -ne 0) { throw "Could not inspect existing EKS clusters. No resources were applied." }
$ClusterNamesParsed = @($ClusterNames | ConvertFrom-Json)
$ClusterAlreadyExists = $ClusterNamesParsed -contains $ClusterName
if ($ClusterAlreadyExists -and ($EksStateText -notmatch '(?m)^module\.eks\.' -or $EksStateText -notmatch '(?m)^module\.vpc\.')) {
    throw "EKS cluster $ClusterName already exists but the local iac-eks state does not track module.eks and module.vpc. Restore the matching terraform.tfstate before applying."
}
$ExistingVpcIds = & aws ec2 describe-vpcs --region $Region --filters "Name=tag:Name,Values=togglemaster-vpc" --query "Vpcs[].VpcId" --output json
if ($LASTEXITCODE -ne 0) { throw "Could not inspect existing VPCs. No resources were applied." }
$ExistingVpcList = @($ExistingVpcIds | ConvertFrom-Json)
if ($ExistingVpcList.Count -gt 0 -and $EksStateText -notmatch '(?m)^module\.vpc\.') {
    throw "VPC togglemaster-vpc already exists but iac-eks state does not track module.vpc. Restore the matching terraform.tfstate before applying."
}

$ReqStateFile = Join-Path $Requirements "terraform.tfstate"
if (Test-Path -LiteralPath $ReqStateFile) {
    $ReqStateResources = & terraform "-chdir=$Requirements" state list
    if ($LASTEXITCODE -ne 0) { throw "Could not read iac-req Terraform state. No resources were applied." }
    $ReqStateText = ($ReqStateResources | Out-String)
}
else {
    $ReqStateText = ""
}
$ExistingQueueUrl = & aws sqs get-queue-url --queue-name analytics-queue --region $Region --query QueueUrl --output text 2>$null
$QueueAlreadyExists = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($ExistingQueueUrl | Out-String).Trim()) -and (($ExistingQueueUrl | Out-String).Trim() -ne "None"))
if ($QueueAlreadyExists -and $ReqStateText -notmatch '(?m)^aws_sqs_queue\.analytics_queue$') {
    throw "SQS queue analytics-queue exists but iac-req state does not track aws_sqs_queue.analytics_queue. Restore the matching terraform.tfstate before applying."
}
$ExistingTableStatus = & aws dynamodb describe-table --table-name ToggleMasterAnalytics --region $Region --query Table.TableStatus --output text 2>$null
$TableAlreadyExists = ($LASTEXITCODE -eq 0 -and (($ExistingTableStatus | Out-String).Trim() -eq "ACTIVE"))
if ($TableAlreadyExists -and $ReqStateText -notmatch '(?m)^aws_dynamodb_table\.analytics_table$') {
    throw "DynamoDB table ToggleMasterAnalytics exists but iac-req state does not track aws_dynamodb_table.analytics_table. Restore the matching terraform.tfstate before applying."
}
$ExistingRepositories = & aws ecr describe-repositories --region $Region --query "repositories[].repositoryName" --output text 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not inspect ECR repositories. No resources were applied." }
$ToggleMasterRepositories = @((($ExistingRepositories -join " ") -split '\s+') | Where-Object { $_ -like "togglemaster/*" })
if ($ToggleMasterRepositories.Count -gt 0 -and $EksStateText -notmatch 'aws_ecr_repository\.service') {
    throw "ToggleMaster ECR repositories already exist but iac-eks state does not track them. Restore the matching terraform.tfstate before applying."
}

# State 1: shared data resources used by Evaluation and Analytics.
Invoke-Terraform -Directory $Requirements -Arguments @("apply", "-input=false", "-auto-approve") -Description "Apply SQS and DynamoDB"

# State 2, phase 1: create the VPC and EKS API/node group before Helm resources.
# Terraform's Helm provider needs a reachable cluster; this phase is intentionally
# automated here so the operator does not have to remember a second apply.
Invoke-Terraform -Directory $EksTerraform -Arguments @(
    "apply", "-input=false", "-auto-approve",
    "-target=module.vpc",
    "-target=module.eks"
) -Description "Create base VPC and EKS cluster" -UseEksVariables

# Make kubectl usable immediately after the base cluster exists. The Helm provider
# authenticates independently, but we need kubectl to verify real webhook endpoints.
Write-Host "`n== Configure kubectl ==" -ForegroundColor Yellow
& aws eks update-kubeconfig --region $Region --name $ClusterName
if ($LASTEXITCODE -ne 0) { throw "Could not configure kubeconfig for $ClusterName." }

Write-Host "`nWaiting for both worker nodes..." -ForegroundColor Yellow
& kubectl wait --for=condition=Ready nodes --all --timeout=15m
if ($LASTEXITCODE -ne 0) { throw "EKS nodes did not become Ready." }
$NodesJson = (& kubectl get nodes -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw "Could not inspect EKS nodes." }
$ReadyNodes = @($NodesJson.items | Where-Object {
    $_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }
})
if ($ReadyNodes.Count -lt 2) {
    & kubectl get nodes -o wide
    throw "This lab profile requires two Ready worker nodes for the requested app replicas and add-ons; only $($ReadyNodes.Count) Ready node(s) were found."
}

# Phase 2a: install the AWS Load Balancer Controller first. KEDA creates Services,
# and the LBC admission webhook intercepts Service admission requests. Installing both
# Helm releases concurrently can make the API server call a webhook Service with zero
# endpoints, so explicitly wait for the controller and its webhook endpoint first.
Invoke-Terraform -Directory $EksTerraform -Arguments @(
    "apply", "-input=false", "-auto-approve",
    "-target=helm_release.load_balancer_controller"
) -Description "Install AWS Load Balancer Controller first" -UseEksVariables

Write-Host "`nWaiting for AWS Load Balancer Controller deployment..." -ForegroundColor Yellow
& kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=10m
if ($LASTEXITCODE -ne 0) {
    & kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
    & kubectl logs deployment/aws-load-balancer-controller -n kube-system --tail=80
    throw "AWS Load Balancer Controller is not Ready. Check the pod status and logs above before retrying."
}

Write-Host "Waiting for the AWS Load Balancer webhook to have endpoints..." -ForegroundColor Yellow
$WebhookReady = $false
for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
    $WebhookEndpoints = (& kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o "jsonpath={.subsets[*].addresses[*].ip}" 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($WebhookEndpoints)) {
        $WebhookReady = $true
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $WebhookReady) {
    & kubectl get service,endpoints aws-load-balancer-webhook-service -n kube-system
    & kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o wide
    throw "AWS Load Balancer webhook still has no endpoints after 5 minutes. The script stopped before installing KEDA."
}
Write-Host "AWS Load Balancer webhook ready: $WebhookEndpoints" -ForegroundColor Green

# Phase 2b: now install the remaining IAM, EBS CSI, ECR, Metrics Server and KEDA.
# keda.tf also declares an explicit depends_on on the LBC Helm release as a second guard.
Invoke-Terraform -Directory $EksTerraform -Arguments @(
    "apply", "-input=false", "-auto-approve"
) -Description "Apply remaining EKS add-ons, IAM and ECR" -UseEksVariables

Write-Host "`n== Apply gp3 StorageClass ==" -ForegroundColor Yellow
& kubectl apply -f $StorageClass
if ($LASTEXITCODE -ne 0) { throw "Could not apply the gp3 StorageClass." }

foreach ($Deployment in @(
    @{ Name = "ebs-csi-controller"; Namespace = "kube-system" },
    @{ Name = "metrics-server"; Namespace = "kube-system" },
    @{ Name = "aws-load-balancer-controller"; Namespace = "kube-system" },
    @{ Name = "keda-operator"; Namespace = "keda" }
)) {
    Write-Host "Waiting for $($Deployment.Namespace)/$($Deployment.Name)..."
    & kubectl rollout status "deployment/$($Deployment.Name)" -n $Deployment.Namespace --timeout=10m
    if ($LASTEXITCODE -ne 0) {
        throw "Deployment $($Deployment.Namespace)/$($Deployment.Name) is not ready."
    }
}

Write-Host "`nInfrastructure is ready." -ForegroundColor Green
Write-Host "Next: start Docker Desktop and run .\iac-eks\scripts\publish-images.ps1"
Write-Host "Then create your local Secret from the sample (one-time per fresh cluster) and run .\deploy-applications.ps1"
