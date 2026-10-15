[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $false)]
    [string]$ExpectedAccountId = "870737143013",

    # Optional override. The script otherwise reads the active EKS endpoint CIDR,
    # then the local value saved by provision-infrastructure.ps1.
    [Parameter(Mandatory = $false)]
    [string]$AdminCidr
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$Region = "us-east-2"
$ClusterName = "togglemaster-eks"
$EksTerraform = Join-Path $ProjectRoot "iac-eks"
$Requirements = Join-Path $ProjectRoot "iac-req"
$AdminCidrFile = Join-Path $ProjectRoot ".togglemaster-admin-cidr"
$TfvarsFile = Join-Path $EksTerraform "terraform.tfvars"
$PlanPrefix = Join-Path $env:TEMP ("togglemaster-destroy-{0}" -f [guid]::NewGuid().ToString("N"))
$EksPlan = "$PlanPrefix-eks.tfplan"
$ReqPlan = "$PlanPrefix-req.tfplan"
$AwsEndpoints = @(
    "ec2.us-east-2.amazonaws.com",
    "eks.us-east-2.amazonaws.com",
    "elasticloadbalancing.us-east-2.amazonaws.com",
    "ecr.us-east-2.amazonaws.com",
    "sqs.us-east-2.amazonaws.com",
    "dynamodb.us-east-2.amazonaws.com",
    "sts.us-east-2.amazonaws.com",
    "iam.amazonaws.com"
)

foreach ($Tool in @("aws", "terraform", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$Tool' was not found in PATH. Nothing was deleted."
    }
}

Write-Host "Checking DNS resolution before doing anything destructive..." -ForegroundColor Cyan
foreach ($Endpoint in $AwsEndpoints) {
    try {
        Resolve-DnsName -Name $Endpoint -DnsOnly -ErrorAction Stop | Out-Null
        Write-Host "  OK  $Endpoint" -ForegroundColor Green
    }
    catch {
        throw "DNS cannot resolve '$Endpoint'. Nothing was deleted. Restore DNS/network connectivity, then rerun. Original error: $($_.Exception.Message)"
    }
}

$IdentityJson = & aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) {
    throw "AWS STS could not be reached or current credentials are invalid. Nothing was deleted."
}
$Identity = $IdentityJson | ConvertFrom-Json
if ($Identity.Account -ne $ExpectedAccountId) {
    throw "AWS account mismatch. Expected $ExpectedAccountId but current identity is $($Identity.Account). Nothing was deleted."
}
Write-Host "AWS account validated: $($Identity.Account)" -ForegroundColor Green

$ClusterListJson = & aws eks list-clusters --region $Region --output json
if ($LASTEXITCODE -ne 0) { throw "Could not query EKS clusters. Nothing was deleted." }
$ClusterList = $ClusterListJson | ConvertFrom-Json
$ClusterExists = @($ClusterList.clusters) -contains $ClusterName

# Determine the required Terraform variable BEFORE deleting Kubernetes workloads/PVCs.
# Terraform requires this variable even for `terraform destroy` because it is referenced
# by the EKS module configuration. The former script omitted it and failed after deleting PVCs.
if ([string]::IsNullOrWhiteSpace($AdminCidr) -and $ClusterExists) {
    $CidrJson = & aws eks describe-cluster `
        --name $ClusterName `
        --region $Region `
        --query "cluster.resourcesVpcConfig.publicAccessCidrs" `
        --output json
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($CidrJson | Out-String).Trim())) {
        $Cidrs = @($CidrJson | ConvertFrom-Json)
        if ($Cidrs.Count -gt 0) { $AdminCidr = [string]$Cidrs[0] }
    }
}

if ([string]::IsNullOrWhiteSpace($AdminCidr) -and (Test-Path -LiteralPath $AdminCidrFile)) {
    $AdminCidr = (Get-Content -LiteralPath $AdminCidrFile -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($AdminCidr) -and (Test-Path -LiteralPath $TfvarsFile)) {
    $TfvarsText = Get-Content -LiteralPath $TfvarsFile -Raw
    $CidrMatch = [regex]::Match($TfvarsText, '(?m)^\s*admin_cidr\s*=\s*"([^"]+)"')
    if ($CidrMatch.Success) { $AdminCidr = $CidrMatch.Groups[1].Value.Trim() }
}

if ([string]::IsNullOrWhiteSpace($AdminCidr)) {
    # Destroy uses the CIDR only to evaluate the existing Terraform configuration; no
    # apply/update is run. This fallback allows a cleanup to continue after the cluster
    # endpoint has already been removed and no local CIDR file exists.
    $AdminCidr = "0.0.0.0/0"
    Write-Warning "No saved admin_cidr was found and the cluster is absent. Using 0.0.0.0/0 only for the destroy operation; this script does not apply that setting."
}
if ($AdminCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "admin_cidr '$AdminCidr' is not an IPv4 CIDR. Nothing was deleted."
}
Set-Content -LiteralPath $AdminCidrFile -Value $AdminCidr -Encoding ascii -NoNewline
Write-Host "Terraform destroy variable admin_cidr: $AdminCidr" -ForegroundColor Green

# Confirm the local state files exist before any Kubernetes resource or data volume is removed.
# This archive intentionally excludes state files; overlay it on the existing checkout and keep them.
$EksState = Join-Path $EksTerraform "terraform.tfstate"
$ReqState = Join-Path $Requirements "terraform.tfstate"
if (-not (Test-Path -LiteralPath $EksState)) {
    throw "Missing $EksState. Nothing was deleted. Restore the existing Terraform state; do not run destroy from a clean ZIP without the project's state."
}
if (-not (Test-Path -LiteralPath $ReqState)) {
    throw "Missing $ReqState. Nothing was deleted. Restore the existing Terraform state; do not run destroy from a clean ZIP without the project's state."
}

# Verify the current state actually manages the infrastructure that exists in AWS.
# A state file can exist but be empty; do not delete Kubernetes data and only then discover it.
$EksAddresses = & terraform "-chdir=$EksTerraform" state list
if ($LASTEXITCODE -ne 0) { throw "Could not read iac-eks Terraform state. Nothing was deleted." }
$EksAddressText = ($EksAddresses | Out-String)
if ($ClusterExists -and ($EksAddressText -notmatch '(?m)^module\.eks\.' -or $EksAddressText -notmatch '(?m)^module\.vpc\.')) {
    throw "The EKS cluster exists in AWS but iac-eks/terraform.tfstate does not contain module.eks/module.vpc resources. Nothing was deleted; restore the matching state before proceeding."
}
$ExistingVpcIds = & aws ec2 describe-vpcs --region $Region --filters "Name=tag:Name,Values=togglemaster-vpc" --query "Vpcs[].VpcId" --output json
if ($LASTEXITCODE -ne 0) { throw "Could not inspect existing VPCs. Nothing was deleted." }
$ExistingVpcList = @($ExistingVpcIds | ConvertFrom-Json)
if ($ExistingVpcList.Count -gt 0 -and $EksAddressText -notmatch '(?m)^module\.vpc\.') {
    throw "VPC togglemaster-vpc exists but is not tracked by iac-eks/terraform.tfstate. Nothing was deleted; restore the matching state before proceeding."
}
$ExistingRepositories = & aws ecr describe-repositories --region $Region --query "repositories[].repositoryName" --output text 2>$null
if ($LASTEXITCODE -ne 0) { throw "Could not inspect ECR repositories. Nothing was deleted." }
$ToggleMasterRepositories = @((($ExistingRepositories -join " ") -split '\s+') | Where-Object { $_ -like "togglemaster/*" })
if ($ToggleMasterRepositories.Count -gt 0 -and $EksAddressText -notmatch 'aws_ecr_repository\.service') {
    throw "ToggleMaster ECR repositories exist but are not tracked by iac-eks/terraform.tfstate. Nothing was deleted; restore the matching state before proceeding."
}

$ReqAddresses = & terraform "-chdir=$Requirements" state list
if ($LASTEXITCODE -ne 0) { throw "Could not read iac-req Terraform state. Nothing was deleted." }
$ReqAddressText = ($ReqAddresses | Out-String)
$ExistingQueueUrl = & aws sqs get-queue-url --queue-name analytics-queue --region $Region --query QueueUrl --output text 2>$null
$QueueExists = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($ExistingQueueUrl | Out-String).Trim()) -and (($ExistingQueueUrl | Out-String).Trim() -ne "None"))
$ExistingTableStatus = & aws dynamodb describe-table --table-name ToggleMasterAnalytics --region $Region --query Table.TableStatus --output text 2>$null
$TableExists = ($LASTEXITCODE -eq 0 -and (($ExistingTableStatus | Out-String).Trim() -eq "ACTIVE"))
if ($QueueExists -and $ReqAddressText -notmatch '(?m)^aws_sqs_queue\.analytics_queue$') {
    throw "SQS queue analytics-queue exists in AWS but is not tracked by iac-req/terraform.tfstate. Nothing was deleted; restore the matching state before proceeding."
}
if ($TableExists -and $ReqAddressText -notmatch '(?m)^aws_dynamodb_table\.analytics_table$') {
    throw "DynamoDB table ToggleMasterAnalytics exists in AWS but is not tracked by iac-req/terraform.tfstate. Nothing was deleted; restore the matching state before proceeding."
}

function Invoke-Terraform {
    param(
        [Parameter(Mandatory = $true)][string]$Directory,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    Write-Host "`n== $Description ==" -ForegroundColor Yellow
    & terraform "-chdir=$Directory" @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (terraform exit code $LASTEXITCODE). Stop here, inspect the Terraform output, and rerun after correcting the issue; no subsequent resources were processed."
    }
}

# Preflight both Terraform roots and create destroy plans before deleting app resources.
# This catches missing inputs/provider/state errors before PVCs or workloads are touched.
Invoke-Terraform -Directory $Requirements -Arguments @("init", "-input=false", "-no-color") -Description "Initialize SQS/DynamoDB Terraform state"
Invoke-Terraform -Directory $Requirements -Arguments @("validate", "-no-color") -Description "Validate SQS/DynamoDB Terraform"
Invoke-Terraform -Directory $EksTerraform -Arguments @("init", "-input=false", "-no-color") -Description "Initialize EKS Terraform state"
Invoke-Terraform -Directory $EksTerraform -Arguments @("validate", "-no-color") -Description "Validate EKS Terraform"

Invoke-Terraform -Directory $EksTerraform -Arguments @(
    "plan", "-destroy", "-input=false", "-no-color", "-lock-timeout=5m",
    "-var=aws_region=$Region",
    "-var=admin_cidr=$AdminCidr",
    "-out=$EksPlan"
) -Description "Preflight EKS destroy plan"
Invoke-Terraform -Directory $Requirements -Arguments @(
    "plan", "-destroy", "-input=false", "-no-color", "-lock-timeout=5m",
    "-out=$ReqPlan"
) -Description "Preflight SQS/DynamoDB destroy plan"

$ActionDescription = "Delete ToggleMaster Kubernetes workloads, PVC/EBS data, EKS/VPC/ECR, SQS and DynamoDB resources in account $ExpectedAccountId / $Region"
if (-not $PSCmdlet.ShouldProcess($ActionDescription, "Destroy complete ToggleMaster lab (application data will be deleted)")) {
    Remove-Item $EksPlan, $ReqPlan -Force -ErrorAction SilentlyContinue
    return
}

try {
    if ($ClusterExists) {
        Write-Host "Configuring kubectl for $ClusterName..." -ForegroundColor Cyan
        & aws eks update-kubeconfig --region $Region --name $ClusterName
        if ($LASTEXITCODE -ne 0) { throw "Could not configure kubectl. Terraform destroy was not started." }

        $CurrentContext = (& kubectl config current-context).Trim()
        if ($LASTEXITCODE -ne 0 -or $CurrentContext -notlike "*/$ClusterName") {
            throw "kubectl context is not the expected cluster '$ClusterName' (current: '$CurrentContext'). No Terraform destroy was started."
        }

        & kubectl get nodes | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "The EKS API is not reachable. Terraform destroy was not started." }

        Write-Host "Removing the Ingress first so the AWS Load Balancer Controller can delete the ALB..." -ForegroundColor Yellow
        & kubectl delete ingress togglemaster-ingress -n default --ignore-not-found=true --wait=true --timeout=15m
        if ($LASTEXITCODE -ne 0) {
            throw "Ingress deletion did not complete. The ALB may still exist; Terraform destroy was not started. Check the Ingress finalizer/events and rerun."
        }

        Write-Host "Removing KEDA ScaledObject and application HPAs..." -ForegroundColor Yellow
        $KedaCrds = & kubectl get crd scaledobjects.keda.sh --ignore-not-found=true -o name
        if ($LASTEXITCODE -ne 0) { throw "Could not verify the KEDA CRD. Terraform destroy was not started." }
        if (-not [string]::IsNullOrWhiteSpace(($KedaCrds | Out-String).Trim())) {
            & kubectl delete scaledobject analytics-service-scaledobject -n default --ignore-not-found=true --wait=true --timeout=3m
            if ($LASTEXITCODE -ne 0) { throw "Could not delete the Analytics ScaledObject. Terraform destroy was not started." }
        }
        & kubectl delete hpa --all -n default --ignore-not-found=true --wait=true --timeout=3m
        if ($LASTEXITCODE -ne 0) { throw "Could not delete application HPAs. Terraform destroy was not started." }

        # Capture EBS volume IDs before deleting PVCs so deletion can be confirmed.
        $PvJson = & kubectl get pv -o json
        if ($LASTEXITCODE -ne 0) { throw "Could not inspect persistent volumes. Terraform destroy was not started." }
        $PvList = $PvJson | ConvertFrom-Json
        $VolumeIds = @(
            $PvList.items |
                Where-Object { $_.spec.csi.driver -eq "ebs.csi.aws.com" -and $_.spec.claimRef.namespace -eq "default" } |
                ForEach-Object { $_.spec.csi.volumeHandle } |
                Where-Object { $_ -match '^vol-[0-9a-f]+$' } |
                Select-Object -Unique
        )

        $AppDeployments = @(
            "auth-service-app", "auth-service-database",
            "flag-service-app", "flag-service-database",
            "targeting-service-app", "targeting-service-database",
            "evaluation-service-app", "evaluation-service-redis",
            "analytics-service-app"
        )
        Write-Host "Removing application Deployments before their persistent claims..." -ForegroundColor Yellow
        & kubectl delete deployment @AppDeployments -n default --ignore-not-found=true --cascade=foreground --wait=true --timeout=10m
        if ($LASTEXITCODE -ne 0) { throw "Application Deployments did not terminate cleanly. Terraform destroy was not started." }

        $Claims = @("auth-db-pvc", "flag-db-pvc", "targeting-db-pvc")
        & kubectl delete pvc @Claims -n default --ignore-not-found=true --wait=true --timeout=10m
        if ($LASTEXITCODE -ne 0) { throw "PVC deletion did not complete. Terraform destroy was not started." }

        foreach ($VolumeId in $VolumeIds) {
            Write-Host "Waiting for EBS volume $VolumeId to be deleted..." -ForegroundColor Yellow
            $Deleted = $false
            for ($Attempt = 1; $Attempt -le 60; $Attempt++) {
                $Remaining = & aws ec2 describe-volumes --region $Region --filters "Name=volume-id,Values=$VolumeId" --query "Volumes[].VolumeId" --output text
                if ($LASTEXITCODE -ne 0) { throw "Could not check EBS volume $VolumeId. Terraform destroy was not started." }
                $RemainingText = ($Remaining | Out-String).Trim()
                if ([string]::IsNullOrWhiteSpace($RemainingText) -or $RemainingText -eq "None") {
                    $Deleted = $true
                    break
                }
                Start-Sleep -Seconds 10
            }
            if (-not $Deleted) {
                throw "EBS volume $VolumeId still exists after 10 minutes. Terraform destroy was not started; rerun after checking the volume."
            }
        }
    }
    else {
        Write-Host "EKS cluster '$ClusterName' is already absent; skipping Kubernetes cleanup." -ForegroundColor Yellow
    }

    # IMPORTANT: pass every non-default input to destroy, just as provision does.
    Invoke-Terraform -Directory $EksTerraform -Arguments @(
        "destroy", "-input=false", "-auto-approve", "-lock-timeout=5m",
        "-var=aws_region=$Region",
        "-var=admin_cidr=$AdminCidr"
    ) -Description "Destroy EKS, add-ons, IAM, ECR and VPC"

    Invoke-Terraform -Directory $Requirements -Arguments @(
        "destroy", "-input=false", "-auto-approve", "-lock-timeout=5m"
    ) -Description "Destroy SQS and DynamoDB"

    Write-Host "`nToggleMaster infrastructure was destroyed successfully." -ForegroundColor Green
}
finally {
    Remove-Item $EksPlan, $ReqPlan -Force -ErrorAction SilentlyContinue
}
