provider "aws" {
  region = var.aws_region
}

terraform {
  backend "s3" {
    bucket         = "eqaya-infra-tf-state"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "eqaya-tf-locks"
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_elb_service_account" "main" {}

locals {
  name_prefix  = "eqaya-prod"
  db_name      = "eqaya_prod"
  db_username  = "prod_admin"
  tags         = { Environment = "production" }
  uploads_name = "eqaya-prod-uploads-${data.aws_caller_identity.current.account_id}"
  logs_name    = "eqaya-prod-alb-logs-${data.aws_caller_identity.current.account_id}"
}

resource "random_password" "db_password" {
  length  = 40
  special = false
}

resource "random_password" "jwt_secret" {
  length  = 64
  special = false
}

# --- VPC ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${local.name_prefix}-vpc"
  cidr = "10.2.0.0/16"

  azs              = slice(data.aws_availability_zones.available.names, 0, 2)
  public_subnets   = ["10.2.101.0/24", "10.2.102.0/24"]
  private_subnets  = ["10.2.1.0/24", "10.2.2.0/24"]
  database_subnets = ["10.2.201.0/24", "10.2.202.0/24"]

  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_nat_gateway     = true
  single_nat_gateway     = var.enable_single_nat_gateway
  one_nat_gateway_per_az = !var.enable_single_nat_gateway
  enable_vpn_gateway     = false

  create_database_subnet_group = true

  tags = local.tags
}

# Gateway endpoint for S3 is free and removes NAT egress for object I/O.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc.private_route_table_ids

  tags = merge(local.tags, { Name = "${local.name_prefix}-s3-endpoint" })
}

# Interface endpoints are billed per-AZ per-hour. Disabled by default; flip
# var.enable_interface_endpoints once steady-state NAT egress justifies them.
resource "aws_security_group" "vpce_sg" {
  count = var.enable_interface_endpoints ? 1 : 0

  name        = "${local.name_prefix}-vpce-sg"
  description = "HTTPS access from ECS tasks to VPC interface endpoints"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enable_interface_endpoints ? toset([
    "ecr.api",
    "ecr.dkr",
    "logs",
    "secretsmanager"
  ]) : toset([])

  vpc_id              = module.vpc.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc.private_subnets
  security_group_ids  = [aws_security_group.vpce_sg[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-${each.value}-endpoint" })
}

# --- Security Groups ---
resource "aws_security_group" "alb_sg" {
  name        = "${local.name_prefix}-alb-sg"
  description = "Public HTTP/HTTPS ingress for the production ALB"
  vpc_id      = module.vpc.vpc_id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "ecs_sg" {
  name        = "${local.name_prefix}-ecs-sg"
  description = "Production ECS task access"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.tags
}

resource "aws_security_group" "db_sg" {
  name        = "${local.name_prefix}-db-sg"
  description = "PostgreSQL ingress from ECS tasks"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }

  tags = local.tags
}

# --- S3 storage ---
resource "aws_s3_bucket" "uploads" {
  bucket = local.uploads_name
  tags   = local.tags
}

resource "aws_s3_bucket_ownership_controls" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  rule {
    id     = "expire-old-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "STANDARD_IA"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "uploads" {
  bucket = aws_s3_bucket.uploads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.uploads.arn,
        "${aws_s3_bucket.uploads.arn}/*"
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

resource "aws_s3_bucket" "alb_logs" {
  bucket = local.logs_name
  tags   = local.tags
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  rule {
    id     = "rotate-logs"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowELBAccessLogs"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.alb_logs.arn,
          "${aws_s3_bucket.alb_logs.arn}/*"
        ]
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}

# --- Application Load Balancer ---
resource "aws_lb" "prod" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = var.enable_deletion_protection
  drop_invalid_header_fields = true

  access_logs {
    bucket  = aws_s3_bucket.alb_logs.bucket
    prefix  = "alb"
    enabled = true
  }

  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = local.tags
}

resource "aws_lb_target_group" "prod_tg" {
  name        = "${local.name_prefix}-tg"
  port        = var.app_port
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  deregistration_delay = 30

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = local.tags
}

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "prod_cert" {
  domain_name       = "api.${var.domain_name}"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = local.tags
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.prod_cert.domain_validation_options : dvo.domain_name => dvo
  }

  allow_overwrite = true
  name            = each.value.resource_record_name
  records         = [each.value.resource_record_value]
  ttl             = 60
  type            = each.value.resource_record_type
  zone_id         = data.aws_route53_zone.main.zone_id
}

resource "aws_acm_certificate_validation" "prod_cert" {
  certificate_arn         = aws_acm_certificate.prod_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.prod.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.prod.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.prod_cert.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod_tg.arn
  }
}

resource "aws_route53_record" "api" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.prod.dns_name
    zone_id                = aws_lb.prod.zone_id
    evaluate_target_health = true
  }
}

# --- WAF ---
resource "aws_wafv2_web_acl" "api" {
  name  = "${local.name_prefix}-api-waf"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 0

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit_per_5min
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesAnonymousIpList"
    priority = 4

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAnonymousIpList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-anonymous-ip"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesSQLiRuleSet"
    priority = 5

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesSQLiRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-sqli"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-api-waf"
    sampled_requests_enabled   = true
  }

  tags = local.tags
}

resource "aws_wafv2_web_acl_association" "api" {
  resource_arn = aws_lb.prod.arn
  web_acl_arn  = aws_wafv2_web_acl.api.arn
}

# --- ECR ---
resource "aws_ecr_repository" "prod" {
  name                 = "eqaya-prod-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

resource "aws_ecr_lifecycle_policy" "prod" {
  repository = aws_ecr_repository.prod.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 30 production images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["prod-"]
        countType     = "imageCountMoreThan"
        countNumber   = 30
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# --- Secrets ---
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${local.name_prefix}-db-credentials"
  description             = "Database credentials for Eqaya production"
  recovery_window_in_days = 30

  tags = merge(local.tags, { Service = "database" })
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = local.db_username
    password = random_password.db_password.result
    engine   = "postgres"
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = local.db_name
    # sslmode=no-verify keeps the connection encrypted (RDS enforces SSL via
    # rds.force_ssl=1) but skips CA-chain verification. pg >=8.16 parses
    # sslmode=require as verify-full, which rejects RDS's Amazon-issued cert as
    # "self-signed in chain" and crash-loops the app/migrations. no-verify maps
    # to { rejectUnauthorized: false }, matching the app knexfile's intent.
    # (Follow-up hardening: bundle the RDS global CA and switch to verify-full.)
    database_url = "postgresql://${local.db_username}:${urlencode(random_password.db_password.result)}@${aws_db_instance.postgres.address}:5432/${local.db_name}?sslmode=no-verify"
  })
}

resource "aws_secretsmanager_secret" "app_config" {
  name                    = "${local.name_prefix}-app-config"
  description             = "Application runtime secrets for Eqaya production"
  recovery_window_in_days = 30

  tags = merge(local.tags, { Service = "application" })
}

resource "aws_secretsmanager_secret_version" "app_config" {
  secret_id = aws_secretsmanager_secret.app_config.id
  secret_string = jsonencode(merge(
    {
      jwt_secret = random_password.jwt_secret.result
    },
    var.app_secrets
  ))
}

# --- IAM ---
data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "${local.name_prefix}-ecs-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_secrets_policy" {
  name = "${local.name_prefix}-ecs-secrets-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = [
        aws_secretsmanager_secret.db_credentials.arn,
        aws_secretsmanager_secret.app_config.arn
      ]
    }]
  })
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "${local.name_prefix}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json

  tags = local.tags
}

resource "aws_iam_role_policy" "ecs_task_app_policy" {
  name = "${local.name_prefix}-app-runtime-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.uploads.arn,
          "${aws_s3_bucket.uploads.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ]
        # The app sends from an address (info@eqaya.com). SES authorizes against the
        # address identity ARN, not the domain identity ARN — so we must grant both:
        # the domain identity and any address at the domain.
        Resource = [
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/${var.domain_name}",
          "arn:aws:ses:${var.aws_region}:${data.aws_caller_identity.current.account_id}:identity/*@${var.domain_name}"
        ]
      },
      {
        Sid    = "AllowECSExecSessions"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "rds_monitoring_role" {
  name = "${local.name_prefix}-rds-monitoring-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "monitoring.rds.amazonaws.com"
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "rds_monitoring_role" {
  role       = aws_iam_role.rds_monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# --- RDS PostgreSQL ---
# Reject any non-TLS client connection at the server, regardless of what the
# app sets. Complements the client-side DATABASE_SSL/DB_SSL env flags.
resource "aws_db_parameter_group" "postgres" {
  name        = "${local.name_prefix}-pg15"
  family      = "postgres15"
  description = "Production Postgres 15 parameters for Eqaya"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = local.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "postgres" {
  identifier             = "${local.name_prefix}-db"
  instance_class         = var.db_instance_class
  allocated_storage      = var.db_allocated_storage
  max_allocated_storage  = var.db_max_allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  engine                 = "postgres"
  engine_version         = "15.15"
  username               = local.db_username
  password               = random_password.db_password.result
  db_name                = local.db_name
  multi_az               = var.db_multi_az
  deletion_protection    = var.enable_deletion_protection
  skip_final_snapshot    = false
  copy_tags_to_snapshot  = true
  parameter_group_name   = aws_db_parameter_group.postgres.name
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  backup_retention_period = 30
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  monitoring_interval             = 60
  monitoring_role_arn             = aws_iam_role.rds_monitoring_role.arn
  performance_insights_enabled    = true

  tags = local.tags
}

# --- ECS ---
resource "aws_ecs_cluster" "prod" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/${local.name_prefix}"
  retention_in_days = 30

  tags = local.tags
}

resource "aws_ecs_task_definition" "prod_backend" {
  family                   = "${local.name_prefix}-backend"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn

  container_definitions = jsonencode([{
    name      = "eqaya-prod-backend"
    image     = var.app_image
    essential = true

    portMappings = [{
      containerPort = var.app_port
      protocol      = "tcp"
    }]

    environment = concat([
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = tostring(var.app_port) },
      { name = "FRONTEND_URL", value = var.frontend_url },
      { name = "AWS_REGION", value = var.aws_region },
      { name = "AWS_S3_BUCKET", value = aws_s3_bucket.uploads.bucket },
      { name = "DATABASE_SSL", value = "true" },
      { name = "DB_SSL", value = "true" },
      { name = "DB_HOST", value = aws_db_instance.postgres.address },
      { name = "DB_PORT", value = "5432" },
      { name = "DB_NAME", value = local.db_name },
      { name = "DB_USER", value = local.db_username }
      ],
      [for name, value in var.app_environment : { name = name, value = value }]
    )

    secrets = concat([
      {
        name      = "DATABASE_URL"
        valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:database_url::"
      },
      {
        name      = "DB_PASSWORD"
        valueFrom = "${aws_secretsmanager_secret.db_credentials.arn}:password::"
      },
      {
        name      = "JWT_SECRET"
        valueFrom = "${aws_secretsmanager_secret.app_config.arn}:jwt_secret::"
      }
      ],
      [for name in keys(var.app_secrets) : {
        name      = name
        valueFrom = "${aws_secretsmanager_secret.app_config.arn}:${name}::"
      }]
    )

    healthCheck = {
      command     = ["CMD-SHELL", "node -e \"require('http').get('http://localhost:${var.app_port}/health', r => process.exit(r.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))\""]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs_logs.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "backend"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "prod_backend" {
  name            = "${local.name_prefix}-backend"
  cluster         = aws_ecs_cluster.prod.id
  task_definition = aws_ecs_task_definition.prod_backend.arn
  desired_count   = var.desired_count

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  enable_execute_command             = true

  # Roll tasks on every apply so changes that don't alter the task definition
  # (e.g. an updated app_config / app_secrets Secrets Manager value) are picked
  # up — without this, a secrets-only change never restarts the running tasks.
  force_new_deployment = true

  load_balancer {
    target_group_arn = aws_lb_target_group.prod_tg.arn
    container_name   = "eqaya-prod-backend"
    container_port   = var.app_port
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = var.min_capacity
    weight            = 1
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  # Auto-roll back a deploy whose tasks never reach a healthy state.
  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.https]

  lifecycle {
    ignore_changes = [desired_count]
  }

  tags = local.tags
}

resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.prod.name}/${aws_ecs_service.prod_backend.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${local.name_prefix}-cpu-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "ecs_memory" {
  name               = "${local.name_prefix}-memory-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

# --- Cost guardrail ---
resource "aws_budgets_budget" "monthly_prod" {
  count = length(var.budget_alert_emails) > 0 ? 1 : 0

  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }
}

# --- Operational alerting ---
# Distinct from the cost budget above: these page on live-service health.
# Reuses budget_alert_emails as the operator contact list.
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"

  tags = local.tags
}

resource "aws_sns_topic_subscription" "alerts_email" {
  for_each = toset(var.budget_alert_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# 5xx responses coming from the application (target group).
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx" {
  alarm_name          = "${local.name_prefix}-alb-target-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 10
  alarm_description   = "Application is returning 5xx errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.prod.arn_suffix
    TargetGroup  = aws_lb_target_group.prod_tg.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# Tasks failing health checks / dropping out of the target group.
resource "aws_cloudwatch_metric_alarm" "alb_unhealthy_hosts" {
  alarm_name          = "${local.name_prefix}-alb-unhealthy-hosts"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "One or more backend tasks are unhealthy"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = aws_lb.prod.arn_suffix
    TargetGroup  = aws_lb_target_group.prod_tg.arn_suffix
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu_high" {
  alarm_name          = "${local.name_prefix}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "ECS service CPU utilization is sustained high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = aws_ecs_cluster.prod.name
    ServiceName = aws_ecs_service.prod_backend.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "${local.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 85
  alarm_description   = "RDS CPU utilization is sustained high"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}

# Fires while there is still headroom (10GB) before storage autoscaling or a
# full disk become a problem.
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name          = "${local.name_prefix}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 10737418240 # 10 GB in bytes
  alarm_description   = "RDS free storage is running low"
  treat_missing_data  = "notBreaching"

  dimensions = {
    DBInstanceIdentifier = aws_db_instance.postgres.identifier
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}
