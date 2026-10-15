
$ErrorActionPreference = "Stop"

$Region = "us-east-2"
$Registry = "870737143013.dkr.ecr.us-east-2.amazonaws.com"
$RepositoryPrefix = "$Registry/togglemaster"

$Services = @(
    "auth-service",
    "flag-service",
    "targeting-service",
    "evaluation-service",
    "analytics-service"
)

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

# Verify AWS identity
aws sts get-caller-identity --output table
if ($LASTEXITCODE -ne 0) {
    throw "AWS CLI não autenticado ou sem acesso à conta."
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

# Build and push all images
foreach ($Service in $Services) {
    $ProjectRoot = "C:\posgrad"
    $BuildContext = Join-Path $ProjectRoot "src\$Service"
    $Image = "${RepositoryPrefix}/${Service}:latest"

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

Write-Host "`nTodas as imagens foram publicadas com sucesso." -ForegroundColor Green
