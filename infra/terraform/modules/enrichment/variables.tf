variable "project" {
  type    = string
  default = "challanse"
}

variable "environment" {
  type = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production"
  }
}

variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "vpc_cidr" {
  type = string
}

variable "container_image" {
  type        = string
  description = "Immutable ECR image URI including sha256 digest."
  validation {
    condition     = strcontains(var.container_image, "@sha256:")
    error_message = "container_image must be pinned by sha256 digest"
  }
}

variable "adot_collector_image" {
  type        = string
  description = "Immutable AWS Distro for OpenTelemetry collector image URI including sha256 digest."
  validation {
    condition     = strcontains(var.adot_collector_image, "@sha256:")
    error_message = "adot_collector_image must be pinned by sha256 digest"
  }
}

variable "certificate_arn" {
  type        = string
  description = "Validated ACM certificate for the Cloudflare-proxied enrichment origin hostname."
}

variable "monthly_budget_usd" {
  type        = number
  description = "Mandatory operator-approved monthly AWS budget."
  validation {
    condition     = var.monthly_budget_usd > 0
    error_message = "monthly_budget_usd must be greater than zero"
  }
}

variable "budget_email" {
  type = string
}

variable "github_repository" {
  type    = string
  default = "tcbhagat/challanse"
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Existing GitHub Actions OIDC provider ARN in this AWS account."
}

variable "multi_az" {
  type = bool
}

variable "api_desired_count" {
  type = number
}

variable "worker_desired_count" {
  type = number
}

variable "services_enabled" {
  type        = bool
  description = "Fail-closed switch. Keep false until the runtime secret and migrations are ready."
  default     = false
}

variable "deletion_protection" {
  type        = bool
  description = "Protect production RDS and ALB resources from accidental deletion."
}

variable "nat_gateway_count" {
  type = number
  validation {
    condition     = contains([1, 2], var.nat_gateway_count)
    error_message = "nat_gateway_count must be one or two"
  }
}
