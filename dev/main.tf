provider "aws" {
  region = "us-east-1"
}

terraform {
  backend "s3" {
    bucket = "eqaya-infra-tf-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1"
  }
}

# --- AWS Secrets Manager for Credentials ---
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "eqaya-dev-db-credentials"
  description = "Database credentials for Eqaya Dev environment"

  recovery_window_in_days = 7

  tags = {
    Environment = "development"
    Service     = "database"
  }
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    username = "dev_admin"
    password = random_password.db_password.result
    engine   = "postgres"
    port     = 5432
    dbname   = "eqaya_dev"
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

  name = "eqaya-dev-vpc"
  cidr = "10.1.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.1.101.0/24", "10.1.102.0/24"]
  private_subnets = ["10.1.1.0/24", "10.1.2.0/24"]
  database_subnets = ["10.1.201.0/24", "10.1.202.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # Cost saving: Only 1 NAT for Dev
  enable_vpn_gateway = false

  create_database_subnet_group = true

  tags = { Environment = "development" }
}

# --- Security Groups ---
resource "aws_security_group" "dev_sg" {
  name        = "eqaya-dev-sg"
  description = "Security group for dev environment"
  vpc_id      = module.vpc.vpc_id

  # SSH Access
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP Access
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS Access
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Internal Traffic (App <-> DB <-> Cache)
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.1.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Environment = "development"
  }
}

# --- IAM Role for EC2 to access Secrets Manager ---
resource "aws_iam_role" "ec2_secrets_role" {
  name = "eqaya-dev-ec2-secrets-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy" "ec2_secrets_policy" {
  name = "eqaya-dev-ec2-secrets-policy"
  role = aws_iam_role.ec2_secrets_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = aws_secretsmanager_secret.db_credentials.arn
    }]
  })
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "eqaya-dev-ec2-profile"
  role = aws_iam_role.ec2_secrets_role.name
}

# --- Elastic IP for EC2 ---
resource "aws_eip" "dev_eip" {
  domain = "vpc"
  instance = aws_instance.dev_server.id

  tags = {
    Name        = "eqaya-dev-eip"
    Environment = "development"
  }
}

# --- EC2 Development Server (t2.large) ---
resource "aws_instance" "dev_server" {
  ami           = "ami-0c7217cdde317cfec" # Ubuntu 22.04 LTS
  instance_type = "t2.large"              # 8GB RAM Intel Instance

  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.dev_sg.id]
  associate_public_ip_address = true
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
              #!/bin/bash
              set -e

              # Log all output for debugging
              exec > >(tee /var/log/user-data.log)
              exec 2>&1

              echo "Starting EC2 user-data script..."

              apt-get update -y
              apt-get install -y awscli jq docker.io nginx postgresql-client certbot python3-certbot-nginx

              # Start Docker
              systemctl start docker
              systemctl enable docker
              usermod -a -G docker ubuntu

              # Fetch database credentials from Secrets Manager
              aws secretsmanager get-secret-value \
                --secret-id ${aws_secretsmanager_secret.db_credentials.name} \
                --region us-east-1 \
                --query SecretString \
                --output text > /home/ubuntu/db_credentials.json

              chown ubuntu:ubuntu /home/ubuntu/db_credentials.json
              chmod 600 /home/ubuntu/db_credentials.json

              # Create helper script to get RDS endpoint
              cat > /home/ubuntu/get_db_host.sh <<'DBHOST'
              #!/bin/bash
              # Get RDS endpoint from AWS
              aws rds describe-db-instances \
                --db-instance-identifier eqaya-dev-db \
                --region us-east-1 \
                --query 'DBInstances[0].Endpoint.Address' \
                --output text
              DBHOST

              chmod +x /home/ubuntu/get_db_host.sh
              chown ubuntu:ubuntu /home/ubuntu/get_db_host.sh

              # Remove default nginx config
              rm -f /etc/nginx/sites-enabled/default

              # Configure nginx for SSL with Let's Encrypt
              cat > /etc/nginx/sites-available/app.conf <<'NGINX'
              server {
                  listen 80;
                  server_name ${var.dev_domain_name};

                  # ACME challenge location for Let's Encrypt
                  location /.well-known/acme-challenge/ {
                      root /var/www/certbot;
                  }

                  location / {
                      proxy_pass http://localhost:8080;
                      proxy_set_header Host $host;
                      proxy_set_header X-Real-IP $remote_addr;
                      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                      proxy_set_header X-Forwarded-Proto $scheme;
                  }

                  location /health {
                      return 200 "OK";
                      add_header Content-Type text/plain;
                  }
              }
              NGINX

              # Enable the site
              ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf

              # Test nginx config
              nginx -t

              # Start nginx
              systemctl restart nginx
              systemctl enable nginx

              # Create directory for certbot webroot
              mkdir -p /var/www/certbot
              chown -R www-data:www-data /var/www/certbot

              echo "Waiting 90 seconds for DNS to propagate..."
              sleep 90

              # Get Let's Encrypt SSL certificate
              echo "Requesting SSL certificate from Let's Encrypt..."
              certbot --nginx \
                -d ${var.dev_domain_name} \
                --non-interactive \
                --agree-tos \
                --email admin@eqaya.com \
                --redirect \
                --no-eff-email || echo "Certbot failed, check logs at /var/log/letsencrypt/letsencrypt.log"

              # Set up auto-renewal cron job (runs twice daily)
              echo "0 0,12 * * * root certbot renew --quiet --nginx" > /etc/cron.d/certbot-renew
              chmod 644 /etc/cron.d/certbot-renew

              # Create renewal hook to reload nginx after renewal
              mkdir -p /etc/letsencrypt/renewal-hooks/post
              cat > /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh <<'HOOK'
              #!/bin/bash
              systemctl reload nginx
              HOOK
              chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh

              echo "SSL certificate setup complete!"
              echo "User-data script finished successfully."
              EOF

  tags = {
    Name        = "Eqaya-Dev-Workstation"
    Environment = "development"
  }
}

# --- RDS Database (t4g.medium) ---
resource "aws_db_instance" "postgres" {
  identifier           = "eqaya-dev-db"
  instance_class       = "db.t4g.medium" # 4GB RAM, Graviton
  allocated_storage    = 20
  engine               = "postgres"
  engine_version       = "15.15"
  username             = jsondecode(aws_secretsmanager_secret_version.db_credentials.secret_string)["username"]
  password             = jsondecode(aws_secretsmanager_secret_version.db_credentials.secret_string)["password"]
  db_name              = "eqaya_dev"

  multi_az             = false
  skip_final_snapshot  = true
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.dev_sg.id]

  backup_retention_period = 7
  backup_window          = "03:00-04:00"
  maintenance_window     = "sun:04:00-sun:05:00"

  tags = {
    Environment = "development"
  }
}

# --- ElastiCache Redis (Free Tier) ---
resource "aws_elasticache_cluster" "redis" {
  cluster_id           = "eqaya-dev-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.dev_redis_subnet.name
  security_group_ids   = [aws_security_group.dev_sg.id]

  tags = {
    Environment = "development"
  }
}

resource "aws_elasticache_subnet_group" "dev_redis_subnet" {
  name       = "eqaya-dev-redis-subnet"
  subnet_ids = module.vpc.private_subnets

  tags = {
    Environment = "development"
  }
}

# --- IAM Role for ECS Task Execution ---
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "eqaya-dev-ecs-task-execution-role"

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
  name = "eqaya-dev-ecs-secrets-policy"
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

# --- Route53 Configuration for Dev Subdomain ---
data "aws_route53_zone" "main" {
  name         = var.root_domain_name
  private_zone = false
}

resource "aws_route53_record" "dev" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.dev_domain_name
  type    = "A"
  ttl     = 300
  records = [aws_eip.dev_eip.public_ip]
}

# --- ECR Repository ---
resource "aws_ecr_repository" "dev" {
  name                 = "eqaya-dev"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = "development"
  }
}

resource "aws_ecr_lifecycle_policy" "dev" {
  repository = aws_ecr_repository.dev.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus     = "any"
        countType     = "imageCountMoreThan"
        countNumber   = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# --- ECS Cluster ---
resource "aws_ecs_cluster" "dev" {
  name = "eqaya-dev-cluster"

  tags = {
    Environment = "development"
  }
}

# --- ECS Task Definition ---
resource "aws_ecs_task_definition" "dev_backend" {
  family                   = "eqaya-dev-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name  = "eqaya-backend"
    image = "nginx:latest" # Replace with your actual image

    portMappings = [{
      containerPort = 80
      protocol      = "tcp"
    }]

    secrets = [{
      name      = "DB_CREDENTIALS"
      valueFrom = aws_secretsmanager_secret.db_credentials.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/eqaya-dev"
        "awslogs-region"        = "us-east-1"
        "awslogs-stream-prefix" = "backend"
      }
    }
  }])

  tags = {
    Environment = "development"
  }
}

# --- CloudWatch Log Group for ECS ---
resource "aws_cloudwatch_log_group" "ecs_logs" {
  name              = "/ecs/eqaya-dev"
  retention_in_days = 7

  tags = {
    Environment = "development"
  }
}

# --- ECS Service (Fargate Spot) - OPTIONAL ---
# Note: In dev, you can run containers directly on EC2 to save costs
# This ECS service is optional and can be commented out if not needed
resource "aws_ecs_service" "dev_backend" {
  name            = "eqaya-dev-backend"
  cluster         = aws_ecs_cluster.dev.id
  task_definition = aws_ecs_task_definition.dev_backend.arn
  desired_count   = 0 # Set to 0 to disable, or 1 to enable

  network_configuration {
    subnets          = module.vpc.private_subnets
    security_groups  = [aws_security_group.dev_sg.id]
    assign_public_ip = false
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 100
  }

  tags = {
    Environment = "development"
  }
}
