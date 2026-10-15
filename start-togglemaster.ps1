[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$AdminCidr,

    [Parameter(Mandatory = $false)]
    [switch]$SkipImagePublish
)

$ErrorActionPreference = "Stop"
$ProjectRoot = $PSScriptRoot
$SecretFile = Join-Path $ProjectRoot "eks\global-files\secrets-togglemaster.yaml"
$ExpectedAccountId = "870737143013"

# Check every local prerequisite before creating/updating any AWS resource.
foreach ($Tool in @("aws", "terraform", "kubectl", "docker")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Required command '$Tool' was not found in PATH. No infrastructure was changed."
    }
}

$IdentityJson = & aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0) { throw "AWS CLI is not authenticated. No infrastructure was changed." }
$Identity = $IdentityJson | ConvertFrom-Json
if ($Identity.Account -ne $ExpectedAccountId) {
    throw "AWS account mismatch. Expected $ExpectedAccountId, received $($Identity.Account). No infrastructure was changed."
}

try {
    docker info | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Docker daemon is unavailable." }
}
catch {
    throw "Start Docker Desktop before running this start script. No AWS resources were changed. $($_.Exception.Message)"
}

if (-not (Test-Path -LiteralPath $SecretFile)) {
    throw "Secret file not found: $SecretFile. Create it from secrets-togglemaster-sample.yaml and replace placeholders before starting; no AWS resources were changed."
}
$SecretText = Get-Content -LiteralPath $SecretFile -Raw
if ($SecretText -match "CHANGE_ME|<VARIABLE_VALUE>|REPLACE_ME") {
    throw "The local Secret still contains placeholder values. Edit $SecretFile before starting; no AWS resources were changed."
}

Write-Host "Starting complete ToggleMaster environment (AWS account $ExpectedAccountId / us-east-2)..." -ForegroundColor Cyan

$ProvisionScript = Join-Path $ProjectRoot "provision-infrastructure.ps1"
if (-not (Test-Path $ProvisionScript)) { throw "Missing $ProvisionScript" }
if ([string]::IsNullOrWhiteSpace($AdminCidr)) {
    & $ProvisionScript
}
else {
    & $ProvisionScript -AdminCidr $AdminCidr
}
if ($LASTEXITCODE -ne 0) { throw "Infrastructure provisioning failed. Images were not published and applications were not deployed." }

if (-not $SkipImagePublish) {
    $PublishScript = Join-Path $ProjectRoot "iac-eks\scripts\publish-images.ps1"
    if (-not (Test-Path $PublishScript)) { throw "Missing $PublishScript" }
    & $PublishScript
    if ($LASTEXITCODE -ne 0) { throw "Image publishing failed. Applications were not deployed." }
}
else {
    Write-Warning "-SkipImagePublish was supplied. The script assumes all five latest images already exist in ECR."
}

$DeployScript = Join-Path $ProjectRoot "deploy-applications.ps1"
if (-not (Test-Path $DeployScript)) { throw "Missing $DeployScript" }
& $DeployScript
if ($LASTEXITCODE -ne 0) { throw "Application deployment failed. Inspect the error above; infrastructure is preserved for troubleshooting." }

Write-Host "`nToggleMaster start workflow completed." -ForegroundColor Green
