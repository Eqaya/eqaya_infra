output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "alb_dns_name" {
  description = "DNS name of the Application Load Balancer"
  value       = aws_lb.prod.dns_name
}

output "api_domain" {
  description = "API domain name"
  value       = "api.${var.domain_name}"
}

output "rds_endpoint" {
  description = "RDS database endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "db_secret_arn" {
  description = "ARN of the database credentials secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.prod.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.prod_backend.name
}

output "certificate_arn" {
  description = "ARN of the SSL certificate"
  value       = aws_acm_certificate.prod_cert.arn
}

output "ecr_repository_url" {
  description = "Production backend ECR repository URL"
  value       = aws_ecr_repository.prod.repository_url
}

output "uploads_bucket" {
  description = "S3 bucket for production user uploads"
  value       = aws_s3_bucket.uploads.bucket
}

output "alb_logs_bucket" {
  description = "S3 bucket for ALB access logs"
  value       = aws_s3_bucket.alb_logs.bucket
}

output "waf_web_acl_arn" {
  description = "ARN of the API WAF Web ACL"
  value       = aws_wafv2_web_acl.api.arn
}

output "alerts_topic_arn" {
  description = "ARN of the SNS topic for operational CloudWatch alarms"
  value       = aws_sns_topic.alerts.arn
}
