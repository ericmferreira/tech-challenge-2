$ErrorActionPreference = "Stop"

$terraformDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent $terraformDir
$repos = (& terraform "-chdir=$terraformDir" output -json ecr_repository_urls | ConvertFrom-Json)

$services = @{
    "auth-service"       = @{ Port = "8001"; Deployment = "k8s\auth-service-files\deployment.yaml" }
    "flag-service"       = @{ Port = "8002"; Deployment = "k8s\flag-service-files\deployment.yaml" }
    "targeting-service"  = @{ Port = "8003"; Deployment = "k8s\targeting-service-files\deployment.yaml" }
    "evaluation-service" = @{ Port = "8004"; Deployment = "k8s\evaluation-service-files\deployment.yaml" }
    "analytics-service"  = @{ Port = "8005"; Deployment = "k8s\analytics-service-files\deployment.yaml" }
}

foreach ($service in $services.Keys) {
    $file = Join-Path $projectRoot $services[$service].Deployment
    if (-not (Test-Path $file)) { throw "Manifest not found: $file. Keep this folder next to the project's src/ and k8s/ directories." }

    $text = Get-Content $file -Raw
    $imageUrl = "$($repos.$service):lab-1"
    $text = $text.Replace("image: $service`:latest", "image: $imageUrl")

    # Correct only the app's HTTP startupProbe. Database startup probes use exec and remain unchanged.
    $port = $services[$service].Port
    $pattern = '(?s)(startupProbe:\s*\r?\n\s+httpGet:\s*\r?\n\s+path:\s*/health\s*\r?\n\s+port:\s*)8001'
    $text = [regex]::Replace($text, $pattern, ('$1' + $port), 1)

    Set-Content -Path $file -Value $text -NoNewline -Encoding utf8
    Write-Host "Patched $service image and startup probe in $file"
}

foreach ($relativeFile in @(
    "k8s\auth-service-files\pvc.yaml",
    "k8s\flag-service-files\pvc.yaml",
    "k8s\targeting-service-files\pvc.yaml"
)) {
    $file = Join-Path $projectRoot $relativeFile
    if (-not (Test-Path $file)) { throw "PVC manifest not found: $file" }
    $text = Get-Content $file -Raw
    if ($text -notmatch '(?m)^\s*storageClassName:') {
        $text = [regex]::Replace($text, '(?m)^spec:\s*$', "spec:`r`n  storageClassName: gp3", 1)
        Set-Content -Path $file -Value $text -NoNewline -Encoding utf8
    }
    Write-Host "Set gp3 StorageClass in $file"
}

Write-Host ""
Write-Host "Review the modified manifests with: git -C `"$projectRoot`" diff -- k8s"
