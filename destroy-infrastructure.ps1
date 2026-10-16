[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ExpectedAccountId = '870737143013',
    [string]$AdminCidr
)

$ErrorActionPreference = 'Stop'

# -WhatIf only skips ShouldProcess; it would not automatically skip the state-only imports below.
# Reject it explicitly so a dry-run cannot mutate Terraform state unexpectedly.
if ($WhatIfPreference) {
    throw 'The destroy script does not support -WhatIf because it may need state-only imports for existing SQS/DynamoDB resources. No AWS resources were deleted. Run normally after reviewing the script and state backups.'
}
$ProjectRoot  = $PSScriptRoot
$Region       = 'us-east-2'
$ClusterName  = 'togglemaster-eks'
$AppNamespace = 'togglemaster'
$LegacyNamespace = 'default'
$EksRoot      = Join-Path $ProjectRoot 'iac-eks'
$ReqRoot      = Join-Path $ProjectRoot 'iac-req'
$CidrFile     = Join-Path $ProjectRoot '.togglemaster-admin-cidr'
$TfvarsFile   = Join-Path $EksRoot 'terraform.tfvars'
$Timestamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$PlanBase     = Join-Path $env:TEMP "togglemaster-destroy-$Timestamp-$([guid]::NewGuid().ToString('N'))"
$EksPlan      = "$PlanBase-eks.tfplan"
$ReqPlan      = "$PlanBase-req.tfplan"

foreach ($Tool in @('aws', 'terraform', 'kubectl')) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$Tool' is missing. No resources were changed."
    }
}
foreach ($Path in @($EksRoot, $ReqRoot)) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "Terraform root not found: $Path. No resources were changed." }
}

# DNS preflight is deliberately read-only and runs before AWS queries, state imports,
# Kubernetes cleanup, or Terraform destroy. This also avoids the earlier long wait on DNS failures.
$AwsEndpoints = @(
    'ec2.us-east-2.amazonaws.com',
    'eks.us-east-2.amazonaws.com',
    'elasticloadbalancing.us-east-2.amazonaws.com',
    'ecr.us-east-2.amazonaws.com',
    'sqs.us-east-2.amazonaws.com',
    'dynamodb.us-east-2.amazonaws.com',
    'sts.us-east-2.amazonaws.com',
    'iam.amazonaws.com'
)
Write-Host 'Checking DNS resolution before doing anything destructive...' -ForegroundColor Cyan
foreach ($Endpoint in $AwsEndpoints) {
    try {
        Resolve-DnsName -Name $Endpoint -DnsOnly -ErrorAction Stop | Out-Null
        Write-Host "  OK  $Endpoint" -ForegroundColor Green
    }
    catch {
        throw "DNS cannot resolve '$Endpoint'. No AWS resources or Kubernetes workloads were deleted. Restore DNS/network connectivity and rerun. Original error: $($_.Exception.Message)"
    }
}

# Verify account before touching Kubernetes or AWS resources.
$IdentityRaw = & aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) { throw 'AWS identity check failed. No resources were changed.' }
$Identity = $IdentityRaw | ConvertFrom-Json
if ($Identity.Account -ne $ExpectedAccountId) {
    throw "Wrong AWS account. Expected $ExpectedAccountId, received $($Identity.Account). No resources were changed."
}
Write-Host "AWS account validated: $($Identity.Account) / $Region" -ForegroundColor Green
Write-Host 'This script will back up local Terraform states before any state reconciliation.' -ForegroundColor Cyan

$ClustersRaw = & aws eks list-clusters --region $Region --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not list EKS clusters. No resources were changed.' }
$ClusterExists = @((($ClustersRaw | ConvertFrom-Json).clusters)) -contains $ClusterName

# Resolve admin_cidr before any destructive operation. It is a required Terraform input,
# including on destroy because it is referenced in the root configuration.
if ([string]::IsNullOrWhiteSpace($AdminCidr) -and $ClusterExists) {
    $Candidate = & aws eks describe-cluster --name $ClusterName --region $Region --query 'cluster.resourcesVpcConfig.publicAccessCidrs[0]' --output text 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($Candidate | Out-String).Trim()) -and ($Candidate | Out-String).Trim() -ne 'None') {
        $AdminCidr = ($Candidate | Out-String).Trim()
    }
}
if ([string]::IsNullOrWhiteSpace($AdminCidr) -and (Test-Path -LiteralPath $CidrFile)) {
    $AdminCidr = (Get-Content -LiteralPath $CidrFile -Raw).Trim()
}
if ([string]::IsNullOrWhiteSpace($AdminCidr) -and (Test-Path -LiteralPath $TfvarsFile)) {
    $Text = Get-Content -LiteralPath $TfvarsFile -Raw
    $Match = [regex]::Match($Text, '(?m)^\s*admin_cidr\s*=\s*"([^"]+)"')
    if ($Match.Success) { $AdminCidr = $Match.Groups[1].Value.Trim() }
}
if ([string]::IsNullOrWhiteSpace($AdminCidr)) {
    try {
        $Ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com' -TimeoutSec 10).ToString().Trim()
        if ($Ip -match '^\d{1,3}(\.\d{1,3}){3}$') { $AdminCidr = "$Ip/32" }
    } catch { }
}
if ([string]::IsNullOrWhiteSpace($AdminCidr) -and -not $ClusterExists) {
    # Destroy-only fallback. This value is never applied to a cluster; it only satisfies
    # Terraform's required input while it plans/destructs resources from state.
    $AdminCidr = '0.0.0.0/0'
    Write-Warning 'No saved admin_cidr was found and the cluster is absent. Using 0.0.0.0/0 for destroy planning only.'
}
if ($AdminCidr -notmatch '^\d{1,3}(\.\d{1,3}){3}/\d{1,2}$') {
    throw "Could not determine a valid admin_cidr ('$AdminCidr'). Nothing was changed. Run with -AdminCidr 'YOUR.PUBLIC.IP/32'."
}
Set-Content -LiteralPath $CidrFile -Value $AdminCidr -Encoding ascii -NoNewline
Write-Host "Resolved admin_cidr: $AdminCidr" -ForegroundColor Green

# A new ZIP does not contain state files. Local state is required and backed up. For SQS/DynamoDB
# only, an existing declared resource can be imported safely into state if it survived a partial teardown.
$EksState = Join-Path $EksRoot 'terraform.tfstate'
$ReqState = Join-Path $ReqRoot 'terraform.tfstate'
foreach ($StatePath in @($EksState, $ReqState)) {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        throw "Terraform state is missing: $StatePath. No resources were changed. Restore the original state file first; do not manually delete the AWS resources."
    }
    if ((Get-Item -LiteralPath $StatePath).Length -eq 0) {
        throw "Terraform state is empty: $StatePath. No resources were changed. Restore the matching state backup first."
    }
}

# Preserve state backups before starting a destructive operation.
Copy-Item -LiteralPath $EksState -Destination "$EksState.backup-$Timestamp" -Force
Copy-Item -LiteralPath $ReqState -Destination "$ReqState.backup-$Timestamp" -Force

function Invoke-Terraform {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$TerraformArgs,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Write-Host "`n== $Label ==" -ForegroundColor Yellow
    & terraform "-chdir=$Root" @TerraformArgs
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (Terraform exit code $LASTEXITCODE). No further stages will run." }
}

# Preflight both state files and BOTH destroy plans BEFORE deleting PVCs or workloads.
Invoke-Terraform -Root $ReqRoot -TerraformArgs @('init', '-input=false', '-no-color') -Label 'Initialize SQS/DynamoDB Terraform root'
Invoke-Terraform -Root $ReqRoot -TerraformArgs @('validate', '-no-color') -Label 'Validate SQS/DynamoDB Terraform root'
Invoke-Terraform -Root $EksRoot -TerraformArgs @('init', '-input=false', '-no-color') -Label 'Initialize EKS Terraform root'
Invoke-Terraform -Root $EksRoot -TerraformArgs @('validate', '-no-color') -Label 'Validate EKS Terraform root'

function Get-TerraformAddresses {
    param([Parameter(Mandatory = $true)][string]$Root)
    $Raw = & terraform "-chdir=$Root" state list
    if ($LASTEXITCODE -ne 0) { throw "Could not read Terraform state at $Root. No AWS resources have been deleted." }
    return @($Raw | ForEach-Object { ("$_").Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

$EksAddresses = @(Get-TerraformAddresses -Root $EksRoot)
$EksStateText = $EksAddresses -join "`n"
$ReqAddresses = @(Get-TerraformAddresses -Root $ReqRoot)
$ReqStateText = $ReqAddresses -join "`n"

if ($ClusterExists -and ($EksStateText -notmatch '(?m)^module\.eks\.' -or $EksStateText -notmatch '(?m)^module\.vpc\.')) {
    throw 'EKS exists in AWS but the local state does not track module.eks and module.vpc. No AWS resources have been deleted; restore/reconcile the matching Terraform state first.'
}
$VpcJson = & aws ec2 describe-vpcs --region $Region --filters 'Name=tag:Name,Values=togglemaster-vpc' --query 'Vpcs[].VpcId' --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect the ToggleMaster VPC. No AWS resources have been deleted.' }
$VpcIds = @($VpcJson | ConvertFrom-Json)
if ($VpcIds.Count -gt 0 -and $EksStateText -notmatch '(?m)^module\.vpc\.') {
    throw 'ToggleMaster VPC exists but is not tracked in iac-eks state. No AWS resources have been deleted; restore/reconcile the matching Terraform state first.'
}
$ReposRaw = & aws ecr describe-repositories --region $Region --query 'repositories[].repositoryName' --output text 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect ECR repositories. No AWS resources have been deleted.' }
$ToggleMasterRepos = @((($ReposRaw -join ' ') -split '\s+') | Where-Object { $_ -like 'togglemaster/*' })
if ($ToggleMasterRepos.Count -gt 0 -and $EksStateText -notmatch '(?m)^aws_ecr_repository\.service') {
    throw 'ToggleMaster ECR repositories exist but are not tracked in iac-eks state. No AWS resources have been deleted; restore/reconcile the matching Terraform state first.'
}

# The queue/table may have survived a previous partial cleanup or may have been created
# before the current local state. Import only these explicitly declared simple resources,
# after making a local state backup, so Terraform can plan their deletion. Import changes
# Terraform state only; it does not delete or modify the AWS resource.
$QueueUrlRaw = & aws sqs get-queue-url --queue-name analytics-queue --region $Region --query QueueUrl --output text 2>$null
$QueueLookupExit = $LASTEXITCODE
$QueueUrl = ($QueueUrlRaw | Out-String).Trim()
$QueueExists = ($QueueLookupExit -eq 0 -and $QueueUrl -notin @('', 'None'))
if ($QueueExists -and -not ($ReqAddresses -contains 'aws_sqs_queue.analytics_queue')) {
    $OtherSqsAddresses = @($ReqAddresses | Where-Object { $_ -match 'aws_sqs_queue\.' })
    if ($OtherSqsAddresses.Count -gt 0) {
        throw "analytics-queue exists but an SQS resource is tracked at a different Terraform address: $($OtherSqsAddresses -join ', '). No AWS resources have been deleted; state mapping needs review."
    }
    if ((Get-Content -LiteralPath (Join-Path $ReqRoot 'analytics-service.tf') -Raw) -notmatch 'resource\s+"aws_sqs_queue"\s+"analytics_queue"') {
        throw 'The iac-req configuration does not declare aws_sqs_queue.analytics_queue. No AWS resources have been deleted; restore the matching Terraform configuration before continuing.'
    }
    Write-Warning "Found existing SQS queue not in Terraform state. Importing $QueueUrl into iac-req state; this does not delete the queue."
    Invoke-Terraform -Root $ReqRoot -TerraformArgs @('import', '-input=false', '-no-color', '-lock-timeout=5m', 'aws_sqs_queue.analytics_queue', $QueueUrl) -Label 'Import existing SQS queue into Terraform state'
    $ReqAddresses = @(Get-TerraformAddresses -Root $ReqRoot)
    if (-not ($ReqAddresses -contains 'aws_sqs_queue.analytics_queue')) {
        throw 'SQS queue import did not create aws_sqs_queue.analytics_queue in state. No AWS resources have been deleted.'
    }
    $ReqStateText = $ReqAddresses -join "`n"
}

$TableStatusRaw = & aws dynamodb describe-table --table-name ToggleMasterAnalytics --region $Region --query 'Table.TableStatus' --output text 2>$null
$TableLookupExit = $LASTEXITCODE
$TableStatus = ($TableStatusRaw | Out-String).Trim()
$TableExists = ($TableLookupExit -eq 0 -and $TableStatus -notin @('', 'None'))
if ($TableExists -and $TableStatus -ne 'ACTIVE') {
    throw "DynamoDB table ToggleMasterAnalytics exists but is not ACTIVE (status: $TableStatus). Wait for it to become ACTIVE, then rerun. No AWS resources have been deleted."
}
if ($TableExists -and -not ($ReqAddresses -contains 'aws_dynamodb_table.analytics_table')) {
    $OtherTableAddresses = @($ReqAddresses | Where-Object { $_ -match 'aws_dynamodb_table\.' })
    if ($OtherTableAddresses.Count -gt 0) {
        throw "ToggleMasterAnalytics exists but a DynamoDB table is tracked at a different Terraform address: $($OtherTableAddresses -join ', '). No AWS resources have been deleted; state mapping needs review."
    }
    if ((Get-Content -LiteralPath (Join-Path $ReqRoot 'analytics-service.tf') -Raw) -notmatch 'resource\s+"aws_dynamodb_table"\s+"analytics_table"') {
        throw 'The iac-req configuration does not declare aws_dynamodb_table.analytics_table. No AWS resources have been deleted; restore the matching Terraform configuration before continuing.'
    }
    Write-Warning 'Found existing DynamoDB table not in Terraform state. Importing ToggleMasterAnalytics into iac-req state; this does not delete the table.'
    Invoke-Terraform -Root $ReqRoot -TerraformArgs @('import', '-input=false', '-no-color', '-lock-timeout=5m', 'aws_dynamodb_table.analytics_table', 'ToggleMasterAnalytics') -Label 'Import existing DynamoDB table into Terraform state'
    $ReqAddresses = @(Get-TerraformAddresses -Root $ReqRoot)
    if (-not ($ReqAddresses -contains 'aws_dynamodb_table.analytics_table')) {
        throw 'DynamoDB table import did not create aws_dynamodb_table.analytics_table in state. No AWS resources have been deleted.'
    }
    $ReqStateText = $ReqAddresses -join "`n"
}

Invoke-Terraform -Root $EksRoot -TerraformArgs @('plan', '-destroy', '-input=false', '-no-color', '-lock-timeout=5m', "-var=aws_region=$Region", "-var=admin_cidr=$AdminCidr", "-out=$EksPlan") -Label 'Preflight EKS destroy plan'
Invoke-Terraform -Root $ReqRoot -TerraformArgs @('plan', '-destroy', '-input=false', '-no-color', '-lock-timeout=5m', "-out=$ReqPlan") -Label 'Preflight SQS/DynamoDB destroy plan'

$Action = "DESTROY all ToggleMaster infrastructure and application data in AWS account $ExpectedAccountId / $Region. PostgreSQL EBS volumes, SQS messages and DynamoDB records will be deleted."
if (-not $PSCmdlet.ShouldProcess($Action, 'Continue with complete destroy')) {
    Remove-Item $EksPlan, $ReqPlan -Force -ErrorAction SilentlyContinue
    return
}

try {
    if ($ClusterExists) {
        Write-Host "`n== Prepare Kubernetes resources for EKS teardown ==" -ForegroundColor Yellow
        & aws eks update-kubeconfig --region $Region --name $ClusterName
        if ($LASTEXITCODE -ne 0) { throw 'Could not configure kubectl. Terraform destroy has not started.' }
        $Context = (& kubectl config current-context).Trim()
        if ($LASTEXITCODE -ne 0 -or $Context -notlike "*/$ClusterName") { throw "Wrong kubectl context '$Context'. Terraform destroy has not started." }
        & kubectl get nodes -o wide | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'EKS API is unreachable. Terraform destroy has not started.' }

        # Remove Ingress objects in both the target namespace and legacy default before
        # deleting the cluster, so the AWS Load Balancer Controller can release ALBs/finalizers.
        foreach ($Ns in @($AppNamespace, $LegacyNamespace)) {
            Write-Host "Removing application Ingress in namespace $Ns..." -ForegroundColor Yellow
            & kubectl delete ingress togglemaster-ingress -n $Ns --ignore-not-found=true --wait=true --timeout=15m
            if ($LASTEXITCODE -ne 0) { throw "Ingress deletion in namespace '$Ns' did not complete. Check its finalizer/ALB before retrying." }
        }

        $KedaCrd = & kubectl get crd scaledobjects.keda.sh --ignore-not-found=true -o name
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($KedaCrd | Out-String).Trim())) {
            foreach ($Ns in @($AppNamespace, $LegacyNamespace)) {
                & kubectl delete scaledobject analytics-service-scaledobject -n $Ns --ignore-not-found=true --wait=true --timeout=3m
                if ($LASTEXITCODE -ne 0) { throw "Could not delete the KEDA ScaledObject in namespace '$Ns'." }
                & kubectl delete triggerauthentication analytics-sqs-auth -n $Ns --ignore-not-found=true --wait=true --timeout=3m
                if ($LASTEXITCODE -ne 0) { throw "Could not delete the Analytics TriggerAuthentication in namespace '$Ns'." }
            }
        }
        $AppHpas = @('analytics-service-hpa','auth-service-hpa','evaluation-service-hpa','flag-service-hpa','targeting-service-hpa')
        foreach ($Ns in @($AppNamespace, $LegacyNamespace)) {
            & kubectl delete hpa @AppHpas -n $Ns --ignore-not-found=true --wait=true --timeout=3m
            if ($LASTEXITCODE -ne 0) { throw "Could not delete application HPAs in namespace '$Ns'." }
        }

        # Capture EBS volumes claimed by either the new application namespace or the old default namespace.
        $PvJson = & kubectl get pv -o json
        if ($LASTEXITCODE -ne 0) { throw 'Could not inspect PVs before deletion.' }
        $PvList = $PvJson | ConvertFrom-Json
        $CleanupNamespaces = @($AppNamespace, $LegacyNamespace)
        $VolumeIds = @($PvList.items | Where-Object {
            $_.spec.csi.driver -eq 'ebs.csi.aws.com' -and
            $_.spec.claimRef -and
            $_.spec.claimRef.namespace -in $CleanupNamespaces
        } | ForEach-Object { $_.spec.csi.volumeHandle } | Where-Object { $_ -match '^vol-[0-9a-f]+$' } | Select-Object -Unique)

        $AppDeployments = @('auth-service-app','auth-service-database','flag-service-app','flag-service-database','targeting-service-app','targeting-service-database','evaluation-service-app','evaluation-service-redis','analytics-service-app')
        foreach ($Ns in @($AppNamespace, $LegacyNamespace)) {
            Write-Host "Removing application Deployments in namespace $Ns..." -ForegroundColor Yellow
            & kubectl delete deployment @AppDeployments -n $Ns --ignore-not-found=true --cascade=foreground --wait=true --timeout=10m
            if ($LASTEXITCODE -ne 0) { throw "Application Deployments in namespace '$Ns' did not terminate cleanly." }
            & kubectl delete pvc auth-db-pvc flag-db-pvc targeting-db-pvc -n $Ns --ignore-not-found=true --wait=true --timeout=10m
            if ($LASTEXITCODE -ne 0) { throw "PVC deletion in namespace '$Ns' did not complete." }
        }

        # Clear remaining namespaced objects (Services, ConfigMaps, Secrets, ServiceAccounts)
        # in the new app namespace. The legacy default namespace is not deleted because it is cluster-owned.
        & kubectl delete namespace $AppNamespace --ignore-not-found=true --wait=true --timeout=10m
        if ($LASTEXITCODE -ne 0) { throw "Namespace '$AppNamespace' did not terminate cleanly. Inspect finalizers before retrying." }

        foreach ($Vol in $VolumeIds) {
            Write-Host "Waiting for EBS volume $Vol to be deleted..." -ForegroundColor Yellow
            $Gone = $false
            for ($i = 0; $i -lt 90; $i++) {
                $Remaining = & aws ec2 describe-volumes --region $Region --filters "Name=volume-id,Values=$Vol" --query 'Volumes[].VolumeId' --output text 2>$null
                if ($LASTEXITCODE -eq 0 -and (($Remaining | Out-String).Trim()) -in @('', 'None')) { $Gone = $true; break }
                Start-Sleep -Seconds 10
            }
            if (-not $Gone) { throw "EBS volume $Vol was not deleted within 15 minutes. Inspect it before rerunning; Terraform destroy has not started." }
        }
    }
    else {
        Write-Host "EKS cluster $ClusterName is already absent; skipping Kubernetes cleanup." -ForegroundColor Yellow
    }

    # Apply the exact destroy plans already validated above. This avoids a second plan
    # with omitted variables or a new refresh after the data volumes have been removed.
    Invoke-Terraform -Root $EksRoot -TerraformArgs @('apply', '-input=false', '-no-color', $EksPlan) -Label 'Apply preflight EKS destroy plan'
    Invoke-Terraform -Root $ReqRoot -TerraformArgs @('apply', '-input=false', '-no-color', $ReqPlan) -Label 'Apply preflight SQS/DynamoDB destroy plan'

    Write-Host "`nTerraform destroy operations completed. Terraform state files were retained. Verify remaining AWS resources before assuming the account is clean." -ForegroundColor Green
}
finally {
    Remove-Item $EksPlan, $ReqPlan -Force -ErrorAction SilentlyContinue
}
