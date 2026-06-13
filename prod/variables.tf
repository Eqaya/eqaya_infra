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
  description = "Public frontend URL allowed by the backend CORS and websocket configuration. www is canonical: the apex eqaya.com 301-forwards to www.eqaya.com (CloudFront), so the browser origin is always https://www.eqaya.com."
  type        = string
  default     = "https://www.eqaya.com"
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "prod"
}

variable "app_image" {
  description = "Container image URI for the production backend. CI passes the pushed ECR image URI."
  type        = string
  default     = "public.ecr.aws/nginx/nginx:stable"
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
  description = "RDS PostgreSQL instance class. Start small and scale up as load grows."
  type        = string
  default     = "db.t4g.small"
}

variable "db_allocated_storage" {
  description = "Initial RDS storage in GiB"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum RDS autoscaled storage in GiB"
  type        = number
  default     = 100
}

variable "db_multi_az" {
  description = "Run RDS Multi-AZ. Off by default to halve compute cost; turn on once customer traffic justifies the failover SLA."
  type        = bool
  default     = false
}

variable "enable_single_nat_gateway" {
  description = "Use a single NAT gateway to reduce cost. Flip to false later for per-AZ egress availability."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = "Provision interface VPC endpoints (ecr.api/dkr, logs, secretsmanager). Off by default - only worth it above ~1.3TB/mo NAT egress."
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

variable "ai_model" {
  description = "Model id used by the backend AI services (Gemini via OpenRouter). Not a secret — managed here so model swaps are a one-line change. Overrides any AI_MODEL left in app_secrets."
  type        = string
  default     = "google/gemini-2.5-flash-lite"
}

variable "client_signups_open" {
  description = "When false, new client sign-ups (full + booking-wizard) are paused. Flip to true to reopen. Does not affect contractor/verifier signups or existing accounts."
  type        = bool
  default     = false
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

variable "waf_rate_limit_per_5min" {
  description = "WAF rate-based rule limit per IP over a 5 minute window. 2000 is conservative; raise as legitimate traffic grows."
  type        = number
  default     = 2000
}
