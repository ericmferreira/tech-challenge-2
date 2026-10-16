[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ProjectRoot = $PSScriptRoot
$Region = "us-east-2"
$ClusterName = "togglemaster-eks"
$ExpectedAccountId = "870737143013"
$Namespace = "togglemaster"
$EksRoot = Join-Path $ProjectRoot "eks"
$SecretFile = Join-Path $EksRoot "global-files\secrets-togglemaster.yaml"

foreach ($Tool in @("aws", "kubectl")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$Tool' was not found in PATH."
    }
}

$AccountId = (& aws sts get-caller-identity --query Account --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AccountId)) {
    throw "AWS CLI is not authenticated."
}
if ($AccountId -ne $ExpectedAccountId) {
    throw "AWS identity mismatch. This project is configured for account $ExpectedAccountId, but the current session is $AccountId."
}

& aws eks update-kubeconfig --region $Region --name $ClusterName
if ($LASTEXITCODE -ne 0) { throw "Could not configure kubectl for $ClusterName." }

$Context = (& kubectl config current-context).Trim()
if ($LASTEXITCODE -ne 0 -or $Context -notmatch "cluster/$ClusterName$") {
    throw "kubectl is not pointing to $ClusterName. Current context: $Context"
}

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    Write-Host "`n== $Description ==" -ForegroundColor Yellow
    & kubectl @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed (kubectl exit code $LASTEXITCODE)."
    }
}

function Apply-Manifest {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $Path = Join-Path $ProjectRoot $RelativePath
    if (-not (Test-Path $Path)) { throw "Manifest not found: $Path" }
    Invoke-Kubectl -Arguments @("apply", "-f", $Path) -Description "Apply $RelativePath"
}

function Wait-Deployment {
    param([Parameter(Mandatory = $true)][string]$Name)
    Invoke-Kubectl -Arguments @(
        "rollout", "status", "deployment/$Name", "-n", $Namespace, "--timeout=10m"
    ) -Description "Wait for Deployment/$Name"
}

function Test-EcrImage {
    param([Parameter(Mandatory = $true)][string]$Service)
    $DigestOutput = & aws ecr describe-images `
        --region $Region `
        --repository-name "togglemaster/$Service" `
        --image-ids imageTag=latest `
        --query "imageDetails[0].imageDigest" `
        --output text 2>$null
    $EcrExitCode = $LASTEXITCODE
    $Digest = ($DigestOutput | Out-String).Trim()

    if ($EcrExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($Digest) -or $Digest -eq "None") {
        throw "Image tag latest for '$Service' was not found in ECR. Run .\iac-eks\scripts\publish-images.ps1 first."
    }
}

# Infrastructure preflight: fail before applying application manifests if the cluster
# is under-provisioned or an essential add-on/webhook is unhealthy.
$NodesJson = (& kubectl get nodes -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw "Could not query EKS nodes." }
$ReadyNodeCount = @($NodesJson.items | Where-Object {
    $_.status.conditions | Where-Object { $_.type -eq "Ready" -and $_.status -eq "True" }
}).Count
if ($ReadyNodeCount -lt 2) {
    & kubectl get nodes -o wide
    throw "Application deployment blocked: this lab profile requires 2 Ready EKS worker nodes but found $ReadyNodeCount. Run .\provision-infrastructure.ps1 and review the node group."
}

foreach ($Deployment in @(
    @{ Name = "ebs-csi-controller"; Namespace = "kube-system" },
    @{ Name = "metrics-server"; Namespace = "kube-system" },
    @{ Name = "aws-load-balancer-controller"; Namespace = "kube-system" },
    @{ Name = "keda-operator"; Namespace = "keda" }
)) {
    & kubectl rollout status "deployment/$($Deployment.Name)" -n $Deployment.Namespace --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        throw "Application deployment blocked: $($Deployment.Namespace)/$($Deployment.Name) is not Ready. Fix infrastructure before applying application manifests."
    }
}

$StorageClassName = (& kubectl get storageclass gp3 -o name 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($StorageClassName)) {
    throw "Application deployment blocked: StorageClass gp3 is missing. Run .\provision-infrastructure.ps1 first."
}
$WebhookAddresses = (& kubectl get endpoints aws-load-balancer-webhook-service -n kube-system -o "jsonpath={.subsets[*].addresses[*].ip}" 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($WebhookAddresses)) {
    throw "Application deployment blocked: AWS Load Balancer Controller webhook has no ready endpoints. Run .\provision-infrastructure.ps1 and inspect the controller logs."
}

$QueueUrl = (& aws sqs get-queue-url --queue-name analytics-queue --region $Region --query QueueUrl --output text 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($QueueUrl) -or $QueueUrl -eq "None") {
    throw "Application deployment blocked: SQS queue analytics-queue is missing. Run .\provision-infrastructure.ps1 first."
}
$TableStatus = (& aws dynamodb describe-table --table-name ToggleMasterAnalytics --region $Region --query Table.TableStatus --output text 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $TableStatus -ne "ACTIVE") {
    throw "Application deployment blocked: DynamoDB table ToggleMasterAnalytics is missing or not ACTIVE (status='$TableStatus')."
}

# Prevent a common startup failure: trying to deploy before all five images exist.
foreach ($Service in @("auth-service", "flag-service", "targeting-service", "evaluation-service", "analytics-service")) {
    Test-EcrImage -Service $Service
}

# Create the shared application namespace before applying any application resources.
# Namespace is cluster-scoped; all app manifests should declare namespace: togglemaster.
$NamespaceManifest = Join-Path $EksRoot "namespace.yaml"
if (-not (Test-Path -LiteralPath $NamespaceManifest -PathType Leaf)) {
    throw "Namespace manifest not found: $NamespaceManifest. Create eks\namespace.yaml with metadata.name: togglemaster before deploying."
}
Apply-Manifest "eks\namespace.yaml"

# Only create the Kubernetes Secret if it does not already exist. This avoids
# overwriting a newly generated service key or credentials during a rerun.
# On a fresh cluster, kubectl --ignore-not-found returns no output when the
# Secret does not exist. Do not call .Trim() on that null output.
$ExistingSecretOutput = & kubectl get secret secrets-togglemaster -n $Namespace --ignore-not-found -o name
$SecretQueryExitCode = $LASTEXITCODE
if ($SecretQueryExitCode -ne 0) { throw "Could not query secrets-togglemaster (kubectl exit code $SecretQueryExitCode)." }
$ExistingSecret = (@($ExistingSecretOutput) -join "`n").Trim()

if ([string]::IsNullOrWhiteSpace($ExistingSecret)) {
    if (-not (Test-Path $SecretFile)) {
        throw "Local Secret file not found. Copy secrets-togglemaster-sample.yaml to secrets-togglemaster.yaml and fill the database passwords and MASTER_KEY first."
    }

    $SecretText = Get-Content $SecretFile -Raw
    if ($SecretText -match "CHANGE_ME|<VARIABLE_VALUE>|REPLACE_ME") {
        throw "The local Secret still contains placeholder values. Edit $SecretFile before deploying."
    }

    Apply-Manifest "eks\global-files\secrets-togglemaster.yaml"
}
else {
    Write-Host "Using existing Kubernetes Secret; it will not be overwritten."
}

# Auth and PostgreSQL must be ready before the service key can be generated.
Apply-Manifest "eks\auth-service-files\configmap.yaml"
Apply-Manifest "eks\auth-service-files\pvc.yaml"
Apply-Manifest "eks\auth-service-files\services.yaml"
Apply-Manifest "eks\auth-service-files\deployment.yaml"
Wait-Deployment "auth-service-database"
Wait-Deployment "auth-service-app"
Apply-Manifest "eks\auth-service-files\hpa.yaml"

# Create one API key for Evaluation Service to call both Flag and Targeting.
# The key is stored in the Kubernetes Secret and is never printed to the console.
$SecretObject = (& kubectl get secret secrets-togglemaster -n $Namespace -o json | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or -not $SecretObject.data.MASTER_KEY) {
    throw "secrets-togglemaster does not contain MASTER_KEY."
}
$MasterKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$SecretObject.data.MASTER_KEY))
$ExistingEncodedKey = $SecretObject.data.EVALUATION_TM_KEY
$ExistingKey = ""
if ($ExistingEncodedKey) {
    $ExistingKey = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$ExistingEncodedKey))
}

$PortForward = $null
$PortForwardOut = Join-Path $env:TEMP "togglemaster-auth-port-forward.out.log"
$PortForwardErr = Join-Path $env:TEMP "togglemaster-auth-port-forward.err.log"
$KubectlCommand = (Get-Command kubectl -CommandType Application).Source

try {
    $PortForward = Start-Process -FilePath $KubectlCommand `
        -ArgumentList @("port-forward", "service/auth-service-app", "18081:8001", "-n", $Namespace) `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $PortForwardOut `
        -RedirectStandardError $PortForwardErr

    $AuthReady = $false
    for ($Attempt = 0; $Attempt -lt 30; $Attempt++) {
        $PortForward.Refresh()
        if ($PortForward.HasExited) {
            $Details = ""
            if (Test-Path $PortForwardErr) { $Details = Get-Content $PortForwardErr -Raw }
            throw "kubectl port-forward exited unexpectedly. $Details"
        }

        try {
            $null = Invoke-RestMethod -Uri "http://127.0.0.1:18081/health" -TimeoutSec 2
            $AuthReady = $true
            break
        }
        catch {
            Start-Sleep -Seconds 2
        }
    }

    if (-not $AuthReady) { throw "Auth Service was not reachable through port-forward on localhost:18081." }

    $KeyIsValid = $false
    if (-not [string]::IsNullOrWhiteSpace($ExistingKey) -and $ExistingKey -notmatch "GENERATED_BY_DEPLOY_SCRIPT|CHANGE_ME|VARIABLE_VALUE") {
        try {
            $null = Invoke-RestMethod `
                -Uri "http://127.0.0.1:18081/validate" `
                -Headers @{ Authorization = "Bearer $ExistingKey" } `
                -TimeoutSec 5
            $KeyIsValid = $true
        }
        catch { $KeyIsValid = $false }
    }

    if (-not $KeyIsValid) {
        $Body = @{ name = "evaluation-service" } | ConvertTo-Json -Compress
        $KeyResponse = Invoke-RestMethod `
            -Method Post `
            -Uri "http://127.0.0.1:18081/admin/keys" `
            -Headers @{ Authorization = "Bearer $MasterKey" } `
            -ContentType "application/json" `
            -Body $Body `
            -TimeoutSec 10

        if ([string]::IsNullOrWhiteSpace($KeyResponse.key)) {
            throw "Auth Service did not return an API key."
        }

        $Patch = @{ stringData = @{ EVALUATION_TM_KEY = [string]$KeyResponse.key } } | ConvertTo-Json -Compress
        Invoke-Kubectl -Arguments @(
            "patch", "secret", "secrets-togglemaster", "-n", $Namespace,
            "--type=merge", "--patch=$Patch"
        ) -Description "Store generated Evaluation API key in Kubernetes Secret"

        Write-Host "Evaluation API key created and stored in the Secret (value not displayed)." -ForegroundColor Green
    }
    else {
        Write-Host "Existing Evaluation API key is valid; keeping it."
    }
}
finally {
    if ($PortForward) {
        $PortForward.Refresh()
        if (-not $PortForward.HasExited) {
            Stop-Process -Id $PortForward.Id -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Item $PortForwardOut, $PortForwardErr -Force -ErrorAction SilentlyContinue
    $MasterKey = $null
    $ExistingKey = $null
}

# Flag and Targeting depend on Auth for API-key validation.
foreach ($Service in @("flag-service", "targeting-service")) {
    Apply-Manifest "eks\$Service-files\configmap.yaml"
    $Pvc = Join-Path $EksRoot "$Service-files\pvc.yaml"
    if (Test-Path $Pvc) { Apply-Manifest "eks\$Service-files\pvc.yaml" }
    Apply-Manifest "eks\$Service-files\services.yaml"
    Apply-Manifest "eks\$Service-files\deployment.yaml"
    Wait-Deployment "$($Service)-database"
    Wait-Deployment "$($Service)-app"
    Apply-Manifest "eks\$Service-files\hpa.yaml"
}

# Evaluation sends events to SQS with its own EKS Pod Identity role.
Apply-Manifest "eks\evaluation-service-files\configmap.yaml"
Apply-Manifest "eks\evaluation-service-files\services.yaml"
Apply-Manifest "eks\evaluation-service-files\deployment.yaml"
Wait-Deployment "evaluation-service-redis"
Wait-Deployment "evaluation-service-app"
Apply-Manifest "eks\evaluation-service-files\hpa.yaml"

# Analytics consumes SQS and writes DynamoDB using its own EKS Pod Identity role.
Apply-Manifest "eks\analytics-service-files\configmap.yaml"
Apply-Manifest "eks\analytics-service-files\services.yaml"
Apply-Manifest "eks\analytics-service-files\deployment.yaml"
Apply-Manifest "eks\analytics-service-files\hpa.yaml"
Invoke-Kubectl -Arguments @(
    "wait", "--for=condition=Ready", "scaledobject/analytics-service-scaledobject",
    "-n", $Namespace, "--timeout=180s"
) -Description "Wait for KEDA ScaledObject"
Wait-Deployment "analytics-service-app"

# ALB Ingress is applied only after the backend Services exist.
Apply-Manifest "eks\global-files\ingress-togglemaster.yaml"

Write-Host "`nWaiting for the ALB hostname..." -ForegroundColor Yellow
$AlbHost = ""
for ($Attempt = 0; $Attempt -lt 90; $Attempt++) {
    $AlbHostOutput = & kubectl get ingress togglemaster-ingress -n $Namespace `
        -o jsonpath="{.status.loadBalancer.ingress[0].hostname}" 2>$null
    $IngressQueryExitCode = $LASTEXITCODE
    # The ALB hostname is empty while AWS is provisioning the load balancer.
    # Normalize empty command output before trimming, so the retry loop keeps working.
    $AlbHost = (@($AlbHostOutput) -join "").Trim()
    if ($IngressQueryExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($AlbHost)) { break }
    Start-Sleep -Seconds 10
}
if ([string]::IsNullOrWhiteSpace($AlbHost)) {
    Write-Warning "The Ingress was applied but the ALB hostname has not appeared yet. Run: kubectl describe ingress togglemaster-ingress -n $Namespace"
}
else {
    Write-Host "`nToggleMaster deployed. ALB: http://$AlbHost" -ForegroundColor Green
}

Write-Host "`nFinal status:" -ForegroundColor Cyan
& kubectl get deployments,services,hpa -n $Namespace
& kubectl get scaledobject,triggerauthentication -n $Namespace
& kubectl get ingress -n $Namespace
