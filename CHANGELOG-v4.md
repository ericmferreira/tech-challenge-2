# ToggleMaster consolidated v4 — repair notes

This package is intended to be extracted **over the existing `C:\posgrad` checkout**, not into a clean replacement directory. It deliberately does not contain Terraform state, `.terraform` caches, local `terraform.tfvars`, the saved admin CIDR, or real Kubernetes Secrets.

## Included changes

- `destroy-infrastructure.ps1` discovers/persists `admin_cidr`, passes required Terraform variables to both destroy planning and destroy execution, verifies state/resources, and generates destroy plans before removing Kubernetes Deployments/PVCs. It fixes the failure where the previous version deleted application resources and then exited on `No value for required variable admin_cidr`.
- `provision-infrastructure.ps1` persists the admin CIDR and checks whether existing AWS resources are tracked in the expected local state before applying. It requires two Ready EKS workers before installing add-ons.
- `iac-eks/main.tf` provisions two `m7i-flex.large` workers to provide enough CPU headroom for app replicas and add-ons.
- `deploy-applications.ps1` preflights worker capacity, critical add-ons, AWS Load Balancer Controller webhook endpoints, StorageClass, SQS/DynamoDB, and the five ECR images before applying application manifests.
- PostgreSQL probes no longer depend on shell/environment expansion of credentials in the probe command. The PostgreSQL containers have resource requests/limits, and Flag/Targeting wait for their database Service before starting.
- Analytics uses Boto3 `1.43.114` with Python 3.12, which supports EKS Pod Identity.
- `publish-images.ps1` supports a targeted `-Services analytics-service` publish as well as the default full five-image publish.
- `start-togglemaster.ps1` provides a single orchestration entry point: validate local prerequisites and Secret, provision AWS, publish images, then deploy applications.

## Important operating notes

- The destroy command is intentionally destructive: it deletes PostgreSQL PVCs/EBS volumes and SQS/DynamoDB, as well as EKS/ECR/ALB resources.
- Keep both local Terraform state files and your real local `eks/global-files/secrets-togglemaster.yaml` when overlaying this package.
- The scripts were statically reviewed in this packaging environment, including parsing the Kubernetes YAML documents. They have not been executed against the user's AWS account; use the preflight plan output to verify the target before confirming destroy.
