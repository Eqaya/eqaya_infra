provider "aws" {
  region = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "eqaya-infra-tf-state"
    key    = "prod/terraform.tfstate"
    region = "us-east-1"
  }
}

# --- AWS Secrets Manager for Credentials ---
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "eqaya-prod-db-credentials"
  description = "Database credentials for Eqaya Production environment"

  recovery_window_in_days = 30

  tags = {
    Environment = "production"
    Service     = "database"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "prod_admin"
    password = random_password.db_password.result
    engine   = "postgres"
    host     = aws_db_instance.postgres.address
    port     = 5432
    dbname   = "eqaya_prod"
  })
}

# Generate secure random password for database
resource "random_password" "db_password" {
  length  = 32
  special = true
}

# --- VPC (Standard Secure with NAT) ---
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "eqaya-prod-vpc"
  cidr = "10.2.0.0/16"

  azs              = ["us-east-1a", "us-east-1b"]
  public_subnets   = ["10.2.101.0/24", "10.2.102.0/24"]
  private_subnets  = ["10.2.1.0/24", "10.2.2.0/24"]
  database_subnets = ["10.2.201.0/24", "10.2.202.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = false # High availability for production
  enable_vpn_gateway = false

  create_database_subnet_group = true

  tags = { Environment = "production" }
}

# --- ALB Security Group ---
# Allows the Internet to hit the Load Balancer
resource "aws_security_group" "alb_sg" {
  name        = "eqaya-prod-alb-sg"
  description = "Controls access to the ALB"
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

  tags = {
    Environment = "production"
  }
}

# --- Security Group for ECS Tasks ---
resource "aws_security_group" "prod_sg" {
  name        = "eqaya-prod-sg"
  description = "Security group for production ECS tasks"
  vpc_id      = module.vpc.vpc_id

  # Only allow traffic from the ALB
  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  # Allow internal VPC traffic for database and cache
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.2.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "production"
  }
}

# --- Application Load Balancer (ALB) ---
resource "aws_lb" "prod" {
  name               = "eqaya-prod-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = module.vpc.public_subnets

  enable_deletion_protection = false # Set to true for real production safety

  tags = {
    Environment = "production"
  }
}

# --- Target Group ---
resource "aws_lb_target_group" "prod_tg" {
  name        = "eqaya-prod-tg"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip" # Required for Fargate

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Environment = "production"
  }
}

# --- Route53 Hosted Zone (Data Source) ---
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# --- SSL Certificate (ACM) ---
resource "aws_acm_certificate" "prod_cert" {
  domain_name       = "api.${var.domain_name}"
  validation_method = "DNS"

  tags = {
    Environment = "production"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# Automatic DNS Validation for the Certificate
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

# --- ALB Listeners ---

# HTTP Listener (Redirects to HTTPS)
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

# HTTPS Listener (Forwards to ECS)
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.prod.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate_validation.prod_cert.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.prod_tg.arn
  }
}

# --- DNS Alias Record ---
# Points api.eqaya.com -> Your ALB
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

# --- IAM Role for ECS Task Execution ---
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "eqaya-prod-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_secrets_policy" {
  name = "eqaya-prod-ecs-secrets-policy"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = aws_secretsmanager_secret.db_credentials.arn
    }]
  })
}

# --- RDS Database (t4g.large for production) ---
resource "aws_db_instance" "postgres" {
  identifier           = "eqaya-prod-db"
  instance_class       = "db.t4g.large" # 8GB RAM, Graviton
  allocated_storage    = 100
  engine               = "postgres"
  engine_version       = "15.15"
  username             = jsondecode(aws_secretsmanager_secret_version.db_credentials.secret_string)["username"]
  password             = jsondecode(aws_secretsmanager_secret_version.db_credentials.secret_string)["password"]
  db_name              = "eqaya_prod"

  multi_az                = true # High availability
  skip_final_snapshot     = false
  final_snapshot_identifier = "eqaya-prod-db-final-snapshot"
  db_subnet_group_name      = module.vpc.database_subnet_group_name
  vpc_security_group_ids    = [aws_security_group.prod_sg.id]

  backup_retention_period = 30
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  tags = {
    Environment = "production"
  }
}

# --- ElastiCache Redis (Production) ---
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "eqaya-prod-redis"
  engine               = "redis"
  node_type            = "cache.t3.small"
  num_cache_nodes      = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.prod_redis_subnet.name
  security_group_ids   = [aws_security_group.prod_sg.id]

  tags = {
    Environment = "production"
  }
}

resource "aws_elasticache_subnet_group" "prod_redis_subnet" {
  name       = "eqaya-prod-redis-subnet"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Environment = "production"
  }
}

# --- ECS Cluster ---
resource "aws_ecs_cluster" "prod" {
  name = "eqaya-prod-cluster"

  tags = {
    Environment = "production"
  }
}

# --- CloudWatch Log Group for ECS ---
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/eqaya-prod"
  retention_in_days = 30

  tags = {
    Environment = "production"
  }
}

# --- ECS Task Definition ---
resource "aws_ecs_task_definition" "prod_backend" {
  family                   = "eqaya-prod-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name  = "eqaya-prod-backend"
    image = "nginx:latest" # Replace with your actual image

    portMappings = [{
      containerPort = 5000
      protocol      = "tcp"
    }]

    secrets = [{
      name      = "DB_CREDENTIALS"
      valueFrom = aws_secretsmanager_secret.db_credentials.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/eqaya-prod"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "backend"
      }
    }
  }])

  tags = {
    Environment = "production"
  }
}

# --- ECS Service (Fargate with ALB Integration) ---
resource "aws_ecs_service" "prod_backend" {
  name            = "eqaya-prod-backend"
  cluster         = aws_ecs_cluster.prod.id
  task_definition = aws_ecs_task_definition.prod_backend.arn
  desired_count   = 2 # Run 2 tasks for high availability
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.prod_tg.arn
    container_name   = "eqaya-prod-backend"
    container_port   = 5000
  }

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.prod_sg.id]
    assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }

  depends_on = [aws_lb_listener.https]

  tags = {
    Environment = "production"
  }
}
