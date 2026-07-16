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

variable "cloudflared_image" {
  type        = string
  description = "Immutable Cloudflare Tunnel connector image URI including sha256 digest."
  validation {
    condition     = strcontains(var.cloudflared_image, "@sha256:")
    error_message = "cloudflared_image must be pinned by sha256 digest"
  }
}

variable "expected_aws_account_id" {
  type        = string
  description = "The environment account ID. Prevents applying production state in the wrong AWS account."
  validation {
    condition     = can(regex("^[0-9]{12}$", var.expected_aws_account_id))
    error_message = "expected_aws_account_id must contain 12 digits"
  }
}

variable "backup_destination_vault_arn" {
  type        = string
  description = "Cross-account AWS Backup vault ARN. Required for production and optional for staging."
  default     = ""
  validation {
    condition     = var.backup_destination_vault_arn == "" || can(regex("^arn:aws:backup:[a-z0-9-]+:[0-9]{12}:backup-vault:", var.backup_destination_vault_arn))
    error_message = "backup_destination_vault_arn must be an AWS Backup vault ARN"
  }
}

variable "ocr_provider" {
  type        = string
  description = "Production must use textract; staging may use deterministic mock OCR."
  validation {
    condition     = contains(["mock", "textract"], var.ocr_provider) && (var.environment != "production" || var.ocr_provider == "textract")
    error_message = "ocr_provider must be textract in production and mock or textract in staging"
  }
}

variable "play_integrity_cloud_project_number" {
  type        = number
  description = "Google Cloud project number linked to the private Play app. Required in production."
  default     = 0
  validation {
    condition     = var.environment != "production" || var.play_integrity_cloud_project_number > 0
    error_message = "Production requires a linked Play Integrity Cloud project number"
  }
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

variable "database_instance_class" {
  type        = string
  description = "Environment-sized RDS instance class. Production must not use a micro class."
  validation {
    condition     = can(regex("^db\\.[a-z0-9.]+$", var.database_instance_class)) && (var.environment != "production" || !endswith(var.database_instance_class, ".micro"))
    error_message = "database_instance_class must be a valid RDS class; production cannot use a micro class"
  }
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
