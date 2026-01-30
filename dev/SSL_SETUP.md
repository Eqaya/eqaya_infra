# SSL Certificate Setup for Development Environment (Manual Installation)

## ⚠️ IMPORTANT: Manual Installation Only

This guide is for **manually installing SSL on an existing EC2 instance** to avoid instance recreation and data loss.

**DO NOT apply Terraform changes** that modify `user_data` as this will force EC2 recreation!

## Overview

Install **Let's Encrypt** SSL certificates on your running EC2 instance using the provided installation script. This provides HTTPS access to `dev.eqaya.com` at no additional cost, without any downtime.

## Prerequisites

1. ✅ EC2 instance is running
2. ✅ Domain `dev.eqaya.com` points to the EC2 Elastic IP
3. ✅ Security group allows ports 80 and 443
4. ✅ Nginx is installed and running
5. ✅ SSH access to the instance

## Quick Installation (Recommended)

### Step 1: Copy the Installation Script

From your local machine:

```bash
cd /home/ubuntu/git_repos/eqaya_infra/dev

# Get EC2 IP from Terraform
cd /home/ubuntu/git_repos/eqaya_infra/dev && terraform output -raw elastic_ip

# Copy script to EC2 instance
scp -i ~/.ssh/eqaya-dev-key.pem install_ssl_manual.sh ubuntu@<EC2_IP>:~/
```

### Step 2: SSH to Instance and Run Script

```bash
# SSH to instance
ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@<EC2_IP>

# Make script executable
chmod +x install_ssl_manual.sh

# Run the script (with sudo)
sudo bash install_ssl_manual.sh dev.eqaya.com admin@eqaya.com
```

**That's it!** The script will:
- ✅ Install certbot
- ✅ Backup existing nginx config
- ✅ Configure nginx for SSL
- ✅ Request SSL certificate from Let's Encrypt
- ✅ Set up auto-renewal
- ✅ Configure HTTP → HTTPS redirect

**Installation time**: ~2-3 minutes

### Step 3: Verify

```bash
# Check certificate
sudo certbot certificates

# Test HTTPS
curl https://dev.eqaya.com/health

# Check auto-renewal
sudo certbot renew --dry-run
```

## Manual Step-by-Step Installation

If you prefer to run commands manually instead of using the script:

### 1. Install Certbot

```bash
sudo apt-get update
sudo apt-get install -y certbot python3-certbot-nginx
```

### 2. Backup Existing Nginx Config

```bash
sudo cp /etc/nginx/conf.d/app.conf /etc/nginx/conf.d/app.conf.backup 2>/dev/null || true
```

### 3. Update Nginx Configuration

```bash
sudo tee /etc/nginx/sites-available/app.conf > /dev/null <<'NGINX'
server {
    listen 80;
    server_name dev.eqaya.com;

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

# Enable site
sudo rm -f /etc/nginx/sites-enabled/default
sudo rm -f /etc/nginx/conf.d/app.conf
sudo ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf

# Test and reload
sudo nginx -t
sudo systemctl reload nginx
```

### 4. Create Certbot Webroot

```bash
sudo mkdir -p /var/www/certbot
sudo chown -R www-data:www-data /var/www/certbot
```

### 5. Request SSL Certificate

```bash
sudo certbot --nginx \
    -d dev.eqaya.com \
    --non-interactive \
    --agree-tos \
    --email admin@eqaya.com \
    --redirect
```

### 6. Set Up Auto-Renewal

```bash
# Create cron job
sudo tee /etc/cron.d/certbot-renew > /dev/null <<CRON
0 0,12 * * * root certbot renew --quiet --nginx
CRON

sudo chmod 644 /etc/cron.d/certbot-renew

# Create renewal hook
sudo mkdir -p /etc/letsencrypt/renewal-hooks/post
sudo tee /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh > /dev/null <<'HOOK'
#!/bin/bash
systemctl reload nginx
HOOK

sudo chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh
```

## SSL Certificate Details

- **Issuer**: Let's Encrypt
- **Domain**: `dev.eqaya.com`
- **Validity**: 90 days (auto-renews at 60 days)
- **Location**: `/etc/letsencrypt/live/dev.eqaya.com/`
- **Renewal**: Automatic via cron (twice daily at 00:00 and 12:00 UTC)
- **Cost**: **$0** (completely free)

## Verification Commands

```bash
# Check certificate status
sudo certbot certificates

# View certificate details
sudo openssl x509 -in /etc/letsencrypt/live/dev.eqaya.com/cert.pem -text -noout

# Test HTTPS connection
curl -I https://dev.eqaya.com

# Check auto-renewal (dry run)
sudo certbot renew --dry-run

# View Let's Encrypt logs
sudo tail -100 /var/log/letsencrypt/letsencrypt.log

# Check nginx config
sudo nginx -t

# View renewal cron job
cat /etc/cron.d/certbot-renew
```

## Troubleshooting

### Certificate Request Failed

**Check DNS:**
```bash
nslookup dev.eqaya.com
# Should return your EC2 Elastic IP
```

**Check ports are open:**
```bash
sudo netstat -tlnp | grep ':80\|:443'
# Should show nginx listening
```

**Check nginx config:**
```bash
sudo nginx -t
```

**View detailed logs:**
```bash
sudo cat /var/log/letsencrypt/letsencrypt.log
```

### Common Issues

| Issue | Solution |
|-------|----------|
| DNS not propagated | Wait 5-10 minutes, verify with `nslookup dev.eqaya.com` |
| Port 80 blocked | Check AWS security group allows inbound port 80 |
| Nginx not running | `sudo systemctl start nginx` |
| Domain mismatch | Update server_name in nginx config |
| Rate limit hit | Let's Encrypt allows 5 failures per hour, wait and retry |

### Manual Renewal

```bash
# Force renewal (if needed before expiry)
sudo certbot renew --force-renewal

# Or re-request certificate
sudo certbot --nginx -d dev.eqaya.com --force-renewal
```

### Rollback

If something goes wrong:

```bash
# Restore backup
sudo cp /etc/nginx/conf.d/app.conf.backup /etc/nginx/conf.d/app.conf 2>/dev/null || true
sudo systemctl reload nginx

# Delete certificate (if needed)
sudo certbot delete --cert-name dev.eqaya.com
```

## Auto-Renewal Details

### How It Works
- Cron job runs twice daily (midnight and noon UTC)
- Checks if certificate expires within 30 days
- If yes, automatically renews
- Runs post-renewal hook to reload nginx
- Logs to `/var/log/letsencrypt/letsencrypt.log`

### Check Next Renewal

```bash
# View cron schedule
sudo systemctl list-timers | grep certbot

# Or check cron
cat /etc/cron.d/certbot-renew
```

### Test Auto-Renewal

```bash
# Dry run (doesn't actually renew)
sudo certbot renew --dry-run
```

## After Installation

### Update Your Application URLs

Once SSL is installed, update any application configurations that reference `http://dev.eqaya.com` to use `https://dev.eqaya.com`.

## Security Notes

1. ✅ Private key secured with `root:root` ownership and `600` permissions
2. ✅ TLS 1.2 and 1.3 enabled by default
3. ✅ Automatic security updates for certificates
4. ✅ HTTP traffic automatically redirected to HTTPS
5. ✅ Certificate includes full chain for compatibility

## Support

### Let's Encrypt Resources
- Documentation: https://certbot.eff.org/
- Community: https://community.letsencrypt.org/
- Rate limits: https://letsencrypt.org/docs/rate-limits/

### Common Certbot Commands

```bash
# List all certificates
sudo certbot certificates

# Delete a certificate
sudo certbot delete --cert-name dev.eqaya.com

# Renew all certificates
sudo certbot renew

# Revoke a certificate
sudo certbot revoke --cert-path /etc/letsencrypt/live/dev.eqaya.com/cert.pem
```

## Cost

**Total Cost**: **$0.00** ✨

Let's Encrypt provides free SSL certificates for everyone!
