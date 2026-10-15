[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("auth-service", "flag-service", "targeting-service", "evaluation-service", "analytics-service")]
    [string[]]$Services = @(
        "auth-service",
        "flag-service",
        "targeting-service",
        "evaluation-service",
        "analytics-service"
    )
)


$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$TerraformDir = Join-Path $ProjectRoot "iac-eks"

$Region = (& terraform "-chdir=$TerraformDir" output -raw aws_region).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Region)) {
    throw "Não foi possível obter aws_region do Terraform. Execute provision-infrastructure.ps1 primeiro."
}

$RepositoryUrls = (& terraform "-chdir=$TerraformDir" output -json ecr_repository_urls | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0 -or -not $RepositoryUrls) {
    throw "Não foi possível obter os repositórios ECR do Terraform. Execute provision-infrastructure.ps1 primeiro."
}

$FirstRepository = [string]$RepositoryUrls.PSObject.Properties["auth-service"].Value
if ([string]::IsNullOrWhiteSpace($FirstRepository) -or $FirstRepository -notmatch '^([^/]+)/') {
    throw "O Terraform retornou uma URL ECR inválida para auth-service."
}
$Registry = $Matches[1]

function Invoke-DockerLogin {
    param(
        [Parameter(Mandatory)]
        [string]$Token,

        [Parameter(Mandatory)]
        [string]$RegistryUrl
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "docker"
    $startInfo.Arguments = "login --username AWS --password-stdin $RegistryUrl"
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    [void]$process.Start()

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()

    $process.StandardInput.WriteLine($Token)
    $process.StandardInput.Close()

    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    if ($stdout) { Write-Host $stdout.Trim() }
    if ($stderr) { Write-Host $stderr.Trim() }

    if ($process.ExitCode -ne 0) {
        throw "Docker login falhou. Código: $($process.ExitCode)"
    }
}

# Verify required tools
foreach ($tool in @("aws", "docker")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Comando '$tool' não encontrado no PATH."
    }
}

# Verify AWS identity matches the ECR account returned by Terraform.
$AwsAccountId = (& aws sts get-caller-identity --query Account --output text).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($AwsAccountId)) {
    throw "AWS CLI não autenticado ou sem acesso à conta."
}
$RegistryAccountId = ($Registry -split '\.')[0]
if ($AwsAccountId -ne $RegistryAccountId) {
    throw "Conta AWS ativa ($AwsAccountId) não corresponde à conta ECR ($RegistryAccountId)."
}

# Verify Docker daemon
docker info | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Docker não está disponível. Verifique se o Docker Desktop está iniciado."
}

# Authenticate to ECR
Write-Host "`nObtendo token temporário do ECR..."
$Token = aws ecr get-login-password --region $Region

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Token)) {
    throw "Não foi possível obter o token do ECR."
}

Invoke-DockerLogin -Token $Token -RegistryUrl $Registry
$Token = $null

# Build and push only selected image(s); with no -Services argument, publish all five.
foreach ($Service in $Services) {
    $BuildContext = Join-Path $ProjectRoot "src\$Service"
    $RepositoryUrl = [string]$RepositoryUrls.PSObject.Properties[$Service].Value
    if ([string]::IsNullOrWhiteSpace($RepositoryUrl)) {
        throw "O Terraform não retornou o repositório ECR para $Service."
    }
    $Image = "${RepositoryUrl}:latest"

    if (-not (Test-Path (Join-Path $BuildContext "Dockerfile"))) {
        throw "Dockerfile não encontrado em: $BuildContext"
    }

    Write-Host "`n========================================"
    Write-Host "Serviço: $Service"
    Write-Host "Imagem:  $Image"
    Write-Host "========================================"

    docker build -t $Image $BuildContext
    if ($LASTEXITCODE -ne 0) {
        throw "Build falhou para $Service."
    }

    docker push $Image
    if ($LASTEXITCODE -ne 0) {
        throw "Push falhou para $Service."
    }

    Write-Host "Imagem publicada: $Image" -ForegroundColor Green
}

Write-Host "`nImagens publicadas: $($Services -join ", ")" -ForegroundColor Green
