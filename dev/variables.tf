variable "aws_region" {
  description = "AWS region for dev environment"
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "SSH key pair name for EC2 instances"
  type        = string
  default     = "eqaya-dev-key"
}

variable "dev_domain_name" {
  description = "Subdomain for development environment"
  type        = string
  default     = "dev.eqaya.com"
}

variable "root_domain_name" {
  description = "Root domain name (must have Route53 hosted zone)"
  type        = string
  default     = "eqaya.com"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "dev"
}
