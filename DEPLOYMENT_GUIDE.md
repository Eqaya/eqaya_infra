# Deployment Guide - Development Environment

This guide explains how to deploy your application to the development environment using EC2 instead of ALB for cost savings.

## Architecture Overview

**Development Setup (Cost-Optimized):**
```
dev.eqaya.com (Route53 subdomain)
    |
    v
EC2 Instance (Elastic IP)
    |
    +-- Nginx (Reverse Proxy) :80
    |       |
    |       v
    +-- Your App (Docker) :8080
    |
    +-- RDS PostgreSQL (Private Subnet)
    +-- ElastiCache Redis (Private Subnet)
```

## Prerequisites

1. **Route53 Hosted Zone** for `eqaya.com` must exist
   ```bash
   # Check if hosted zone exists
   aws route53 list-hosted-zones | grep eqaya.com

   # The hosted zone should already exist if you own the domain
   # Terraform will create the dev.eqaya.com subdomain automatically
   ```

2. **S3 Bucket** for Terraform state
   ```bash
   aws s3 mb s3://eqaya-infra-tf-state --region us-east-1
   aws s3api put-bucket-versioning \
     --bucket eqaya-infra-tf-state \
     --versioning-configuration Status=Enabled
   ```

3. **SSH Key Pair**
   ```bash
   aws ec2 create-key-pair \
     --key-name eqaya-dev-key \
     --query 'KeyMaterial' \
     --output text > eqaya-dev-key.pem
   chmod 400 eqaya-dev-key.pem
   ```

## Step 1: Deploy Infrastructure

```bash
cd dev
terraform init
terraform plan
terraform apply
```

After successful deployment, note the outputs:
```bash
terraform output
```

You should see:
- `dev_url`: http://dev.eqaya.com
- `elastic_ip`: Your EC2's public IP
- `ec2_ssh_command`: SSH command to connect
- `ecr_repository_url`: Where to push Docker images

## Step 2: Verify DNS Configuration

The subdomain `dev.eqaya.com` will be automatically created in your existing `eqaya.com` hosted zone.

Check DNS propagation:
```bash
# Should return your EC2's Elastic IP
dig dev.eqaya.com

# Or use nslookup
nslookup dev.eqaya.com
```

DNS propagation usually takes a few minutes.

## Step 3: Deploy Your Application

### Option A: Deploy via SSH (Manual)

1. **SSH to EC2:**
   ```bash
   ssh -i eqaya-dev-key.pem ec2-user@$(terraform output -raw elastic_ip)
   ```

2. **Login to ECR:**
   ```bash
   aws ecr get-login-password --region us-east-1 | \
     docker login --username AWS --password-stdin <your-ecr-url>
   ```

3. **Pull and run your container:**
   ```bash
   # Get database credentials
   cat ~/db_credentials.json

   # Pull latest image
   docker pull <ecr-repository-url>:latest

   # Stop existing container if running
   docker stop eqaya-app || true
   docker rm eqaya-app || true

   # Run new container
   docker run -d \
     --name eqaya-app \
     -p 8080:80 \
     --restart unless-stopped \
     -e DB_HOST=$(jq -r '.host' ~/db_credentials.json) \
     -e DB_USER=$(jq -r '.username' ~/db_credentials.json) \
     -e DB_PASS=$(jq -r '.password' ~/db_credentials.json) \
     -e DB_NAME=$(jq -r '.dbname' ~/db_credentials.json) \
     -e REDIS_HOST=<redis-endpoint-from-terraform-output> \
     <ecr-repository-url>:latest
   ```

4. **Verify it's running:**
   ```bash
   docker ps
   curl http://localhost:8080/health
   ```

5. **Check nginx is proxying:**
   ```bash
   curl http://localhost/health
   curl http://dev.eqaya.com/health
   ```

### Option B: Deploy via GitHub Actions

1. **Add SSH key to GitHub Secrets:**
   - Go to your GitHub repository settings
   - Add secret: `EC2_SSH_KEY` with contents of `eqaya-dev-key.pem`

2. **Update the workflow** (optional - automated deployment):
   The workflow currently shows deployment commands. To fully automate:
   ```yaml
   - name: Deploy to EC2 via SSM
     run: |
       aws ssm send-command \
         --instance-ids $(aws ec2 describe-instances \
           --filters "Name=tag:Name,Values=Eqaya-Dev-Workstation" \
           --query "Reservations[0].Instances[0].InstanceId" \
           --output text) \
         --document-name "AWS-RunShellScript" \
         --parameters 'commands=[
           "aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin $ECR_REGISTRY",
           "docker pull $ECR_REGISTRY/$ECR_REPOSITORY:latest",
           "docker stop eqaya-app || true",
           "docker rm eqaya-app || true",
           "docker run -d --name eqaya-app -p 8080:80 --restart unless-stopped $ECR_REGISTRY/$ECR_REPOSITORY:latest"
         ]'
   ```

3. **Push to release branch:**
   ```bash
   git add .
   git commit -m "Deploy application"
   git push origin release
   ```

## Application Requirements

Your application must:

1. **Listen on port 80** inside the container (or update the docker run command to map your port to 8080)

2. **Have a `/health` endpoint** that returns HTTP 200

3. **Handle database connections** using environment variables:
   - `DB_HOST`
   - `DB_USER`
   - `DB_PASS`
   - `DB_NAME`
   - `REDIS_HOST`

Example Python (Flask):
```python
import os
from flask import Flask

app = Flask(__name__)

@app.route('/health')
def health():
    return {'status': 'healthy'}, 200

@app.route('/')
def index():
    return {'message': 'Eqaya Dev API'}, 200

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=80)
```

Example Dockerfile:
```dockerfile
FROM python:3.11-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 80

CMD ["python", "app.py"]
```

## Useful Commands

### Check Application Logs
```bash
ssh -i eqaya-dev-key.pem ec2-user@<elastic-ip>
docker logs -f eqaya-app
```

### Restart Application
```bash
ssh -i eqaya-dev-key.pem ec2-user@<elastic-ip>
docker restart eqaya-app
```

### Update Application
```bash
# On your local machine, build and push
docker build -t <ecr-url>:latest .
docker push <ecr-url>:latest

# On EC2
ssh -i eqaya-dev-key.pem ec2-user@<elastic-ip>
docker pull <ecr-url>:latest
docker stop eqaya-app
docker rm eqaya-app
docker run -d --name eqaya-app -p 8080:80 --restart unless-stopped <ecr-url>:latest
```

### Check Nginx Logs
```bash
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
```

### Modify Nginx Config
```bash
sudo nano /etc/nginx/conf.d/app.conf
sudo nginx -t  # Test config
sudo systemctl restart nginx
```

## Database Access

### From EC2:
```bash
# Get credentials
cat ~/db_credentials.json

# Connect to PostgreSQL
psql -h <rds-endpoint> -U dev_admin -d eqaya_dev

# Connect to Redis
redis-cli -h <redis-endpoint>
```

### From Local Machine (via SSH Tunnel):
```bash
# PostgreSQL tunnel
ssh -i eqaya-dev-key.pem -L 5432:<rds-endpoint>:5432 ec2-user@<elastic-ip>
# Then connect: psql -h localhost -U dev_admin -d eqaya_dev

# Redis tunnel
ssh -i eqaya-dev-key.pem -L 6379:<redis-endpoint>:6379 ec2-user@<elastic-ip>
# Then connect: redis-cli -h localhost
```

## Cost Breakdown (without ALB)

- **EC2 t2.large**: ~$67/month
- **RDS db.t4g.medium**: ~$42/month
- **ElastiCache t3.micro**: ~$12/month
- **NAT Gateway**: ~$32/month
- **Elastic IP**: Free (when attached)
- **ECS Fargate**: $0 (disabled by default)
- **Data Transfer**: ~$5-10/month

**Total**: ~$160-165/month (saves $16-20/month vs ALB setup)

## Troubleshooting

### Domain not resolving
```bash
# Check DNS propagation
dig eqaya-dev.com

# Verify Route53 record
aws route53 list-resource-record-sets \
  --hosted-zone-id <zone-id> | grep eqaya-dev
```

### Application not accessible
```bash
# Check if nginx is running
sudo systemctl status nginx

# Check if docker container is running
docker ps

# Check security group rules
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=eqaya-dev-sg"

# Test locally on EC2
curl http://localhost/health
```

### Cannot connect to database
```bash
# Check security group allows EC2 -> RDS
# The dev_sg should allow all traffic within VPC (10.1.0.0/16)

# Test connection from EC2
telnet <rds-endpoint> 5432
```

### Docker container crashes
```bash
# Check logs
docker logs eqaya-app

# Run interactively for debugging
docker run -it --rm <ecr-url>:latest /bin/sh
```

## Cleanup

To destroy all resources:
```bash
cd dev
terraform destroy
```

**Warning**: This will delete:
- EC2 instance
- RDS database (all data)
- ElastiCache cluster
- VPC and networking
- Route53 records (but not the hosted zone)

## Next Steps

Once tested in dev, you can deploy to production which includes:
- Application Load Balancer with SSL/TLS
- SSL certificate for api.eqaya.com
- Multi-AZ RDS for high availability
- Larger instance sizes
- Auto-scaling capabilities
