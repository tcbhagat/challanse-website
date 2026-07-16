terraform {
  backend "s3" {
    key          = "challanse/production/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" { region = "ap-south-1" }

module "enrichment" {
  source                   = "../modules/enrichment"
  environment              = "production"
  vpc_cidr                 = "10.50.0.0/16"
  container_image          = var.container_image
  adot_collector_image     = var.adot_collector_image
  certificate_arn          = var.certificate_arn
  monthly_budget_usd       = var.monthly_budget_usd
  budget_email             = var.budget_email
  github_oidc_provider_arn = var.github_oidc_provider_arn
  multi_az                 = true
  api_desired_count        = 2
  worker_desired_count     = 1
  nat_gateway_count        = 2
  services_enabled         = var.services_enabled
  deletion_protection      = true
}

variable "container_image" { type = string }
variable "adot_collector_image" { type = string }
variable "certificate_arn" { type = string }
variable "monthly_budget_usd" { type = number }
variable "budget_email" { type = string }
variable "github_oidc_provider_arn" { type = string }
variable "services_enabled" {
  type    = bool
  default = false
}

output "ecs_cluster_name" { value = module.enrichment.ecs_cluster_name }
output "api_task_definition_arn" { value = module.enrichment.api_task_definition_arn }
output "private_subnet_ids" { value = module.enrichment.private_subnet_ids }
output "service_security_group_id" { value = module.enrichment.service_security_group_id }
output "alb_dns_name" { value = module.enrichment.alb_dns_name }
output "receipt_queue_url" { value = module.enrichment.receipt_queue_url }
output "dead_letter_queue_url" { value = module.enrichment.dead_letter_queue_url }
output "runtime_secret_arn" { value = module.enrichment.runtime_secret_arn }
output "ecr_repository_url" { value = module.enrichment.ecr_repository_url }
output "github_deploy_role_arn" { value = module.enrichment.github_deploy_role_arn }
