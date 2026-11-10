variable "aws_region" {
  description = "AWS deployment region."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment; use a separate backend key per environment."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "image" {
  description = "Existing private ECR image with an immutable sha256 digest. Publish before applying."
  type        = string
  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[a-z0-9/_-]+@sha256:[a-f0-9]{64}$", var.image))
    error_message = "Use a private ECR image URL with @sha256:<64 hexadecimal characters>."
  }
}

variable "ecr_repository_name" {
  description = "Existing ECR repository name; must match image."
  type        = string
  default     = "devops-task"
}

variable "allowed_cidrs" {
  description = "IPv4 client CIDRs allowed to access port 8080 (for example your public IP /32)."
  type        = list(string)
  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for cidr in var.allowed_cidrs : can(cidrnetmask(cidr)) && cidr != "0.0.0.0/0"])
    error_message = "Provide at least one specific IPv4 CIDR; unrestricted 0.0.0.0/0 is disallowed."
  }
}

variable "instance_type" {
  description = "Instance type; verify eligibility/pricing in your AWS account."
  type        = string
  default     = "t3.micro"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "subnet_cidr" {
  type    = string
  default = "10.42.1.0/24"
}

variable "log_retention_days" {
  description = "CloudWatch log retention period."
  type        = number
  default     = 14
  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
    error_message = "Choose a supported CloudWatch Logs retention period."
  }
}
