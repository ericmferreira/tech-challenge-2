$ErrorActionPreference = "Stop"

$terraformDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $terraformDir

$region = (& terraform "-chdir=$terraformDir" output -raw aws_region).Trim()
$repos = (& terraform "-chdir=$terraformDir" output -json ecr_repository_urls | ConvertFrom-Json)
$accountId = (aws sts get-caller-identity --query Account --output text).Trim()
$registry = "$accountId.dkr.ecr.$region.amazonaws.com"

aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $registry
if ($LASTEXITCODE -ne 0) { throw "ECR login failed." }

$services = @("auth-service", "flag-service", "targeting-service", "evaluation-service", "analytics-service")
foreach ($service in $services) {
    $repoUrl = $repos.$service
    if (-not $repoUrl) { throw "Missing ECR output for $service. Run terraform apply first." }

    $context = Join-Path (Join-Path $projectRoot "src") $service
    if (-not (Test-Path (Join-Path $context "Dockerfile"))) {
        throw "Dockerfile not found at $context. Keep this folder next to the project's src/ and k8s/ directories."
    }

    $tag = "$repoUrl`:lab-1"
    Write-Host "Building $service -> $tag"
    docker build -t $tag $context
    if ($LASTEXITCODE -ne 0) { throw "Docker build failed for $service." }

    docker push $tag
    if ($LASTEXITCODE -ne 0) { throw "Docker push failed for $service." }
}

Write-Host "All five application images were pushed to ECR."
Write-Host "Next run .\scripts\patch-k8s-manifests.ps1 from this folder to update the manifests."
