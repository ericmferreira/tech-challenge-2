# ToggleMaster - AWS EKS Terraform lab

This is a cost-conscious, disposable EKS environment tailored to the uploaded project's existing Kubernetes manifests.

## Design choices

- EKS Kubernetes `1.36`, two public subnets across two AZs.
- One `t3.large` worker with a 30 GiB root disk. This is a starting point for the existing app resource requests, not a performance guarantee.
- No NAT Gateway, no RDS, no ElastiCache, and no AWS Load Balancer created by this Terraform.
- Kubernetes API endpoint is public but restricted to `admin_cidr`; the worker runs in public subnets to avoid NAT costs and receives a public IPv4 address.
- ECR repositories are created for all five app images.
- EBS CSI Driver is installed with EKS Pod Identity for the existing PostgreSQL PVCs.
- A `gp3` StorageClass is provided.
- Metrics Server and a ClusterIP ingress-nginx controller are installed by a separate script. ClusterIP avoids an AWS Load Balancer charge and preserves the current `host: localhost` Ingress flow via port-forward.

## Cost/security notes

EKS control-plane, EC2, EBS volumes, public IPv4, ECR image storage, data transfer and any other created resources may incur charges. Credits may offset charges but do not make resources inherently free. Check the AWS Billing console and set a budget alert before deploying.

The worker is in a public subnet only to avoid NAT Gateway costs. Do not open SSH or broaden the EKS API CIDR to `0.0.0.0/0`. This is a lab trade-off, not a production network design.

The project currently uses ingress-nginx annotations and `ingressClassName: nginx`. The Kubernetes ingress-nginx project was retired in March 2026 and no longer receives security fixes. The provided script installs it only as a short-lived, ClusterIP-only controller for local testing. Do not expose this controller to the internet or use it for production. For a public deployment, plan a migration to AWS Load Balancer Controller/ALB or another maintained controller and adapt the path-rewrite rules.

## Prerequisites

- Terraform >= 1.6
- AWS CLI v2 and credentials with permission to create VPC, EKS, IAM, ECR, EC2 and EBS resources
- kubectl, Helm 3, Docker
- PowerShell 7 or Windows PowerShell
- Your current public IPv4 address

## Provision

1. Keep the extracted `posgrad-eks-terraform` folder beside the project's existing `src/` and `k8s/` folders. Enter the Terraform folder and create the variables file:

   ```powershell
   Set-Location .\posgrad-eks-terraform
   Copy-Item terraform.tfvars.example terraform.tfvars
   notepad terraform.tfvars
   ```

   Set `admin_cidr` to your public IP plus `/32`. Do not use `0.0.0.0/0`.

2. Validate AWS identity and Terraform:

   ```powershell
   aws sts get-caller-identity
   terraform init
   terraform fmt -recursive
   terraform validate
   terraform plan
   terraform apply
   ```

3. Install cluster add-ons:

   ```powershell
   .\scripts\install-lab-addons.ps1
   ```

4. Build and push images. Run from the project root (the directory containing `src/` and `k8s/`):

   ```powershell
   .\scripts\publish-images.ps1
   ```

5. Patch the image references, correct the four HTTP startup-probe ports, and set the three PostgreSQL PVCs to `gp3`:

   ```powershell
   .\\scripts\\patch-k8s-manifests.ps1
   git -C .. diff -- k8s
   ```

   Review the diff. Then return to the project root and apply your ConfigMaps, Secrets, PVCs, Deployments and Services.

6. Apply the existing Ingress manifest. It uses `host: localhost`, so keep the controller local-only:

   ```powershell
   kubectl -n ingress-nginx port-forward service/ingress-nginx-controller 8080:80
   ```

   In another terminal, test paths with `curl.exe -H "Host: localhost" http://127.0.0.1:8080/auth/...` (replace `...` with a valid endpoint). The rewrite rules strip the service prefix.

## Manifest issues found in the uploaded project

- Startup probes use the wrong port for analytics (8005 expected), evaluation (8004), flag (8002) and targeting (8003). Auth uses 8001 correctly. The patch script corrects these ports in the local manifests; review its diff before applying.
- The evaluation Go Dockerfile exposes port 8001, while its `main.go` defaults to port 8004 and the Deployment/Service use 8004. The application default and manifest agree on 8004; Docker `EXPOSE` is documentation only.
- Existing images use local names such as `auth-service:latest`, which nodes in EKS cannot access. Push to ECR and update image references.
- Three PostgreSQL PVCs require the EBS CSI driver and explicit `storageClassName: gp3`.
- The five HPAs require Metrics Server. Their minimum replica count is two; that creates at least ten application pods plus databases, Redis, controller and system pods. Check node capacity after deployment.
- The uploaded archive excludes the original `.env` and secret. Create the Kubernetes Secret from your own secure source; do not commit real credentials to Git or Terraform state.

## Test and clean up

Check:

```powershell
kubectl get nodes -o wide
kubectl get pods -A
kubectl get pvc
kubectl get hpa -A
kubectl get ingress -A
kubectl get events -A --sort-by=.lastTimestamp
```

When finished, delete Kubernetes resources that could create AWS resources (none should be created by the ClusterIP ingress setup), then run:

```powershell
terraform destroy
```

Review the plan carefully. ECR repositories use `force_delete = true` for this disposable lab, so Terraform can delete repositories and images during destroy. EBS volumes with reclaim policy `Delete` can also be deleted; back up anything you need first. The local Terraform state is required to destroy resources reliably.
