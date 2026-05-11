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

variable "frontend_url" {
  description = "Public frontend URL allowed by the backend CORS and websocket configuration"
  type        = string
  default     = "https://eqaya.com"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "app_image" {
  description = "Container image URI for the production backend. CI passes the pushed ECR image URI."
  type        = string
}

variable "app_port" {
  description = "Port exposed by the backend container and target group"
  type        = number
  default     = 5000
}

variable "desired_count" {
  description = "Baseline number of ECS tasks to run"
  type        = number
  default     = 2
}

variable "min_capacity" {
  description = "Minimum ECS service task count"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum ECS service task count"
  type        = number
  default     = 6
}

variable "db_instance_class" {
  description = "RDS PostgreSQL instance class"
  type        = string
  default     = "db.t4g.medium"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB"
  type        = number
  default     = 50
}

variable "db_max_allocated_storage" {
  description = "Maximum RDS autoscaled storage in GiB"
  type        = number
  default     = 200
}

variable "enable_single_nat_gateway" {
  description = "Use a single NAT gateway to reduce cost. Keep false for stronger AZ-level egress availability."
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable production deletion protection on ALB and RDS"
  type        = bool
  default     = true
}

variable "app_environment" {
  description = "Additional non-secret environment variables for the backend container"
  type        = map(string)
  default     = {}
}

variable "app_secrets" {
  description = "Additional application secrets injected into the backend container from Secrets Manager"
  type        = map(string)
  sensitive   = true
  default     = {}
}

variable "monthly_budget_limit_usd" {
  description = "Optional monthly production cost budget limit in USD"
  type        = number
  default     = 400
}

variable "budget_alert_emails" {
  description = "Email addresses for production budget alerts. Leave empty to skip budget creation."
  type        = list(string)
  default     = []
}
