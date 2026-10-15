# Shared application dependencies

This Terraform state owns the `analytics-queue` SQS queue and `ToggleMasterAnalytics` DynamoDB table.

Provision both through the root-level `provision-infrastructure.ps1` script, which applies this state before the EKS state. Keep the local Terraform state file so Terraform can update or destroy the resources without attempting to recreate existing AWS resources.
