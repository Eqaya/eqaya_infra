variable "aws_region" {
  description = "AWS region for production environment"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Domain name for the production environment"
  type        = string
  default     = "eqaya.com"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}
