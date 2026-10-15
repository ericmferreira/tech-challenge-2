# EKS Terraform root

This folder is the single Terraform state for ToggleMaster's VPC/EKS cluster, two-worker managed node group, ECR repositories, IAM roles/Pod Identity associations, EBS CSI, Metrics Server, KEDA, and AWS Load Balancer Controller.

Use the root-level workflow in [`../README.md`](../README.md). Do not run old add-on scripts or apply manifests from the old `k8s/` directories.

`provision-infrastructure.ps1` runs the required two-phase apply because the Helm provider needs the EKS API to be available before installing cluster add-ons. It installs the AWS Load Balancer Controller first and waits for its webhook endpoints before installing KEDA.

`destroy-infrastructure.ps1` supplies both `aws_region` and `admin_cidr` to Terraform. Before removing workloads or PVCs, it validates the local state files and runs non-mutating destroy plans for both Terraform roots. It removes the ALB Ingress and PVC-backed EBS volumes only after those preflight checks pass.

The two `m7i-flex.large` workers cost more than a one-node lab but provide capacity for the specified application replica counts and cluster add-ons. Review AWS pricing/credits and use the root-level destroy script when the lab is no longer needed.
