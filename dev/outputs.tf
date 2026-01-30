output "vpc_id" {
  description = "ID of the VPC"
  value       = module.vpc.vpc_id
}

output "dev_url" {
  description = "URL to access the development application (HTTPS with Let's Encrypt)"
  value       = "https://${var.dev_domain_name}"
}

output "dev_url_http" {
  description = "HTTP URL (redirects to HTTPS)"
  value       = "http://${var.dev_domain_name}"
}

output "dev_domain" {
  description = "Development domain name"
  value       = var.dev_domain_name
}

output "elastic_ip" {
  description = "Elastic IP address for EC2 instance"
  value       = aws_eip.dev_eip.public_ip
}

output "ec2_instance_id" {
  description = "ID of the EC2 instance"
  value       = aws_instance.dev_server.id
}

output "ec2_ssh_command" {
  description = "SSH command to connect to EC2 instance"
  value       = "ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@${aws_eip.dev_eip.public_ip}"
}

output "rds_endpoint" {
  description = "RDS database endpoint"
  value       = aws_db_instance.postgres.endpoint
}

output "redis_endpoint" {
  description = "Redis cluster endpoint"
  value       = aws_elasticache_cluster.redis.cache_nodes[0].address
}

output "db_secret_arn" {
  description = "ARN of the database credentials secret in Secrets Manager"
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "database_connection_info" {
  description = "Database connection information"
  value = {
    host     = aws_db_instance.postgres.address
    port     = 5432
    database = "eqaya_dev"
    username = "dev_admin"
    secret_arn = aws_secretsmanager_secret.db_credentials.arn
  }
  sensitive = false
}

output "ecr_repository_url" {
  description = "URL of the ECR repository"
  value       = aws_ecr_repository.dev.repository_url
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.dev.name
}

output "ecs_service_name" {
  description = "Name of the ECS service"
  value       = aws_ecs_service.dev_backend.name
}

# --- SSL Certificate Information ---
output "ssl_certificate_commands" {
  description = "Commands to check SSL certificate status on EC2"
  value = <<-EOT

  SSH to instance:
    ${format("ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@%s", aws_eip.dev_eip.public_ip)}

  Check SSL certificate status:
    sudo certbot certificates

  Check user-data logs:
    sudo tail -f /var/log/user-data.log

  Test HTTPS:
    curl https://${var.dev_domain_name}/health

  Manual renewal (if needed):
    sudo certbot renew --dry-run
  EOT
}

output "ssl_setup_info" {
  description = "SSL certificate setup information"
  value = {
    provider       = "Let's Encrypt"
    method         = "Certbot with nginx"
    domain         = var.dev_domain_name
    auto_renewal   = "Twice daily via cron"
    certificate_location = "/etc/letsencrypt/live/${var.dev_domain_name}/"
    setup_time     = "~4-5 minutes after instance launch"
  }
}
