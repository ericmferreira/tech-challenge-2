variable "aws_region" {
  description = "AWS region."
  type        = string
  default     = "us-east-2"
}

variable "project_name" {
  description = "Short project name; used in AWS resource names."
  type        = string
  default     = "togglemaster"
}

variable "cluster_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.36"
}

variable "admin_cidr" {
  description = "Public IPv4 CIDR allowed to access the EKS Kubernetes API, e.g. 203.0.113.10/32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "Use a valid IPv4 CIDR. For personal access, use your public IP with /32, not 0.0.0.0/0."
  }
}

variable "node_instance_type" {
  description = "EKS managed worker instance type; verify regional availability and pricing before provisioning."
  type        = string
  default     = "m7i-flex.large"
}

variable "node_disk_size" {
  description = "Worker root EBS volume in GiB."
  type        = number
  default     = 30
}
