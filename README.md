# Eqaya Infrastructure

Terraform infrastructure for Eqaya development and production environments with automated CI/CD deployment.

## Infrastructure Overview

### Development Environment (`dev/`)
- **VPC**: Multi-AZ setup with public, private, and database subnets
- **EC2**: t2.large instance with Elastic IP and Docker (nginx reverse proxy included)
- **Route53**: DNS for eqaya-dev.com pointing to EC2
- **RDS PostgreSQL**: db.t4g.medium (4GB RAM, Graviton processor)
- **ElastiCache Redis**: cache.t3.micro for caching
- **ECR**: Docker image repository
- **Secrets Manager**: Secure credential storage for database
- **CloudWatch Logs**: Application logging
- **No ALB**: Cost-optimized setup - deploy directly to EC2

### Production Environment (`prod/`)
- Ready for deployment (not yet applied)
- Includes SSL/TLS with ACM certificate for `api.eqaya.com`
- Multi-AZ RDS with backups
- Auto-scaling capable setup

## Architecture

### Development (Cost-Optimized)
```
dev.eqaya.com (Route53 subdomain)
    |
    v
EC2 t2.large (Elastic IP)
  - Nginx reverse proxy :80
  - Docker containers :8080
    |
    +-- RDS PostgreSQL (Database Subnet)
    +-- ElastiCache Redis (Private Subnet)
    +-- Secrets Manager (for credentials)
```

### Production (with High Availability)
```
api.eqaya.com (Route53 + SSL)
    |
    v
Application Load Balancer (Public Subnet)
    |
    v
ECS Fargate Tasks (Private Subnet, Multi-AZ)
    |
    +-- RDS PostgreSQL Multi-AZ (Database Subnet)
    +-- ElastiCache Redis (Private Subnet)
    +-- Secrets Manager (for credentials)
```

## Prerequisites

1. **AWS Account** with appropriate permissions
2. **AWS CLI** configured with credentials
3. **Terraform** >= 1.0
4. **Route53 Hosted Zone** for `eqaya.com` (should already exist since you own the domain):
   ```bash
   # Verify it exists
   aws route53 list-hosted-zones | grep eqaya.com

   # Terraform will automatically create the dev.eqaya.com subdomain
   ```

5. **GitHub Repository** with the following secrets configured:
   - `AWS_ACCESS_KEY_ID`
   - `AWS_SECRET_ACCESS_KEY`

6. **S3 Bucket** for Terraform state:
   ```bash
   aws s3 mb s3://eqaya-infra-tf-state --region us-east-1
   aws s3api put-bucket-versioning \
     --bucket eqaya-infra-tf-state \
     --versioning-configuration Status=Enabled
   ```

7. **SSH Key Pair** for EC2 access:
   ```bash
   aws ec2 create-key-pair \
     --key-name eqaya-dev-key \
     --query 'KeyMaterial' \
     --output text > eqaya-dev-key.pem
   chmod 400 eqaya-dev-key.pem
   ```

## Deployment

### Option 1: Automated Deployment (via GitHub Actions)

Push to the `release` branch to automatically deploy:

```bash
git add .
git commit -m "Deploy infrastructure"
git push origin release
```

The CI/CD pipeline will:
1. Deploy Terraform infrastructure
2. Build your Docker image
3. Push to ECR
4. Show deployment commands for EC2 (manual deployment step required)

### Option 2: Manual Deployment

```bash
# Navigate to dev environment
cd dev

# Initialize Terraform
terraform init

# Review changes
terraform plan

# Apply infrastructure
terraform apply

# Get outputs
terraform output
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/deploy.yml`) runs on:
- Push to `release` branch
- Pull requests to `release` branch
- Manual trigger via workflow_dispatch

### Pipeline Steps:
1. **Infrastructure Deployment**
   - Terraform init, validate, plan, apply

2. **Application Deployment**
   - Docker build
   - Push to ECR
   - Force ECS service update

## Application Deployment

Your application must:

1. **Have a Dockerfile** in the repository root
2. **Expose port 80** in the container
3. **Implement `/health` endpoint** returning HTTP 200

After infrastructure is deployed, SSH to EC2 and deploy:

```bash
# SSH to EC2
ssh -i eqaya-dev-key.pem ec2-user@<elastic-ip>

# Login to ECR
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin <ecr-url>

# Pull and run
docker pull <ecr-url>:latest
docker run -d --name eqaya-app -p 8080:80 --restart unless-stopped <ecr-url>:latest

# Check nginx proxies to it
curl http://dev.eqaya.com
```

See [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) for detailed deployment instructions.

## Accessing Resources

After deployment, Terraform will output:

```bash
# View all outputs
terraform output

# Access application
terraform output -raw dev_url
# Visit: http://dev.eqaya.com

# SSH to EC2
terraform output -raw ec2_ssh_command

# ECR Repository
terraform output -raw ecr_repository_url
```

## Database Credentials

Database credentials are stored in AWS Secrets Manager:

```bash
# Retrieve from AWS Console or CLI
aws secretsmanager get-secret-value \
  --secret-id eqaya-dev-db-credentials \
  --query SecretString \
  --output text | jq .
```

Credentials are automatically injected into:
- ECS containers via the `DB_CREDENTIALS` environment variable
- EC2 instance at `/home/ec2-user/db_credentials.json`

## Cost Estimates

### Development (Cost-Optimized)
- **EC2 t2.large**: ~$67/month
- **RDS db.t4g.medium**: ~$42/month
- **ElastiCache t3.micro**: ~$12/month
- **NAT Gateway**: ~$32/month
- **Elastic IP**: Free (when attached)
- **Route53**: ~$0.50/month
- **Data Transfer**: ~$5-10/month

**Total**: ~$160-165/month

### Production (High Availability)
- **ALB**: ~$16/month
- **ECS Fargate**: ~$20-30/month
- **RDS db.t4g.large Multi-AZ**: ~$170/month
- **ElastiCache t3.small**: ~$25/month
- **NAT Gateway (2x)**: ~$64/month
- **ACM Certificate**: Free
- **Route53**: ~$0.50/month

**Total**: ~$300-350/month

## Security

- Database passwords auto-generated (32 characters)
- Stored in AWS Secrets Manager
- ECS tasks run in private subnets
- Only ALB is publicly accessible
- Security groups restrict access
- SSH restricted to EC2 bastion

## Customization

### Change Container Image

Update the `image` field in `dev/main.tf` at line 277:
```hcl
image = "your-registry/your-image:tag"
```

### Modify Resource Sizes

Edit `dev/main.tf`:
- EC2: line 141 (`instance_type`)
- RDS: line 174 (`instance_class`, `allocated_storage`)
- Redis: line 200 (`node_type`)
- ECS: line 271 (`cpu`, `memory`)

### Add Environment Variables to ECS

Edit `dev/main.tf` container_definitions:
```hcl
environment = [
  { name = "NODE_ENV", value = "development" },
  { name = "API_URL", value = "https://api.example.com" }
]
```

## Troubleshooting

### ECS Tasks Not Starting
```bash
# Check ECS task logs
aws logs tail /ecs/eqaya-dev --follow

# Check service events
aws ecs describe-services \
  --cluster eqaya-dev-cluster \
  --services eqaya-dev-backend
```

### ALB Health Checks Failing
- Ensure your app exposes port 80
- Implement `/health` endpoint returning HTTP 200
- Check security groups allow ALB -> ECS traffic

### Terraform State Lock
```bash
# If state is locked
aws dynamodb delete-item \
  --table-name terraform-locks \
  --key '{"LockID": {"S": "eqaya-infra-tf-state/dev/terraform.tfstate-md5"}}'
```

## Cleanup

To destroy all resources:

```bash
cd dev
terraform destroy
```

**Warning**: This will delete all data including databases.

## Production Deployment

Production is configured but not deployed. When ready:

1. Ensure Route53 hosted zone exists for `eqaya.com`
2. Review production costs (higher instance sizes, Multi-AZ)
3. Update branch strategy in GitHub Actions
4. Deploy:
   ```bash
   cd prod
   terraform init
   terraform apply
   ```

## Support

For issues or questions, contact the infrastructure team.
