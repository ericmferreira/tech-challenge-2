$ErrorActionPreference = "Stop"

$terraformDir = Split-Path -Parent $PSScriptRoot
$region = (& terraform "-chdir=$terraformDir" output -raw aws_region).Trim()
$clusterName = (& terraform "-chdir=$terraformDir" output -raw cluster_name).Trim()

aws eks update-kubeconfig --region $region --name $clusterName
if ($LASTEXITCODE -ne 0) { throw "Could not configure kubectl." }

kubectl apply -f (Join-Path $terraformDir "k8s-aws\storageclass-gp3.yaml")
if ($LASTEXITCODE -ne 0) { throw "Could not create gp3 StorageClass." }

# Metrics Server is needed by the existing CPU-based HPAs.
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
helm upgrade --install metrics-server metrics-server/metrics-server --namespace kube-system
if ($LASTEXITCODE -ne 0) { throw "Metrics Server installation failed." }

# Existing Ingress uses ingressClassName: nginx and NGINX-specific regex/rewrite annotations.
# ClusterIP avoids creating a billable AWS Load Balancer; use kubectl port-forward for access.
# IMPORTANT: ingress-nginx was retired in March 2026. Use only for this short-lived local lab.
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx `
  --namespace ingress-nginx --create-namespace `
  --set controller.service.type=ClusterIP `
  --set controller.ingressClass=nginx `
  --set controller.ingressClassResource.name=nginx
if ($LASTEXITCODE -ne 0) { throw "Ingress NGINX installation failed." }

Write-Host ""
Write-Host "After applying your manifests, run:"
Write-Host "kubectl -n ingress-nginx port-forward service/ingress-nginx-controller 8080:80"
Write-Host "Then test http://localhost:8080/auth/... (and /flag, /targeting, /evaluation, /analytics)."
