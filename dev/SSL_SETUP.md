# SSL Certificate Setup for Development Environment

## Overview

The development environment now uses **Let's Encrypt** for free SSL certificates via Certbot. This provides HTTPS access to `dev.eqaya.com` at no additional cost.

## What's Configured

- **SSL Provider**: Let's Encrypt (free, auto-renewing)
- **Method**: Certbot with nginx plugin
- **Domain**: `dev.eqaya.com`
- **Auto-renewal**: Runs twice daily via cron
- **Redirect**: HTTP automatically redirects to HTTPS

## Deployment Steps

### 1. Apply Terraform Changes

```bash
cd /home/ubuntu/git_repos/eqaya_infra/dev

# Review changes
terraform plan

# Apply changes (this will recreate the EC2 instance)
terraform apply
```

**Note**: The EC2 instance will be recreated because user_data changed. This is expected.

### 2. Wait for Certificate Issuance

After the instance launches, the user-data script will:
1. Install certbot and dependencies (~2 minutes)
2. Configure nginx
3. Wait 90 seconds for DNS propagation
4. Request SSL certificate from Let's Encrypt (~1 minute)
5. Configure auto-renewal

**Total time**: ~4-5 minutes after instance is running

### 3. Verify SSL Setup

```bash
# SSH to the instance
ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@$(terraform output -raw ec2_public_ip)

# Check user-data log
sudo tail -f /var/log/user-data.log

# Check certbot status
sudo certbot certificates

# Check nginx config
sudo nginx -t

# View Let's Encrypt logs if issues
sudo cat /var/log/letsencrypt/letsencrypt.log
```

### 4. Test HTTPS Access

```bash
# Test from local machine
curl https://dev.eqaya.com/health

# Should return: OK
# Should have valid SSL certificate
```

## SSL Certificate Details

- **Issuer**: Let's Encrypt
- **Validity**: 90 days (auto-renews every 60 days)
- **Renewal**: Automatic via cron (runs at midnight and noon daily)
- **Certificate Location**: `/etc/letsencrypt/live/dev.eqaya.com/`

## Auto-Renewal

The certificate automatically renews via:
- **Cron job**: `/etc/cron.d/certbot-renew`
- **Runs**: Twice daily (00:00 and 12:00 UTC)
- **Command**: `certbot renew --quiet --nginx`
- **Post-renewal hook**: Automatically reloads nginx

## Manual Renewal (if needed)

```bash
# SSH to instance
ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@<ec2-ip>

# Test renewal (dry run)
sudo certbot renew --dry-run

# Force renewal (if needed before expiry)
sudo certbot renew --force-renewal

# Check certificate status
sudo certbot certificates
```

## Troubleshooting

### Certificate Request Failed

**Check DNS propagation:**
```bash
# From local machine
nslookup dev.eqaya.com

# Should return the Elastic IP of your EC2 instance
```

**Check user-data logs:**
```bash
sudo tail -100 /var/log/user-data.log
```

**Check Let's Encrypt logs:**
```bash
sudo cat /var/log/letsencrypt/letsencrypt.log
```

**Common issues:**
1. **DNS not propagated**: Wait 5-10 minutes and retry
2. **Port 80 blocked**: Check security group allows port 80
3. **Nginx not running**: `sudo systemctl status nginx`

### Manual Certificate Request

If the automatic request failed, manually request:

```bash
# SSH to instance
ssh -i ~/.ssh/eqaya-dev-key.pem ubuntu@<ec2-ip>

# Request certificate manually
sudo certbot --nginx \
  -d dev.eqaya.com \
  --non-interactive \
  --agree-tos \
  --email admin@eqaya.com \
  --redirect
```

### Certificate Not Renewing

```bash
# Check cron job exists
cat /etc/cron.d/certbot-renew

# Test renewal
sudo certbot renew --dry-run

# Check systemd timer (alternative to cron)
sudo systemctl status certbot.timer
```

## Nginx Configuration

After certbot runs, nginx config at `/etc/nginx/sites-available/app.conf` will have:

```nginx
server {
    listen 443 ssl;
    server_name dev.eqaya.com;

    ssl_certificate /etc/letsencrypt/live/dev.eqaya.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/dev.eqaya.com/privkey.pem;

    # ... proxy configuration ...
}

server {
    listen 80;
    server_name dev.eqaya.com;
    return 301 https://$server_name$request_uri;
}
```

## Cost

**Total additional cost**: $0

Let's Encrypt certificates are completely free.

## Security Notes

1. **Certificate files** are stored in `/etc/letsencrypt/live/dev.eqaya.com/`
2. **Private key** has `root:root` ownership with `600` permissions
3. **Auto-renewal** ensures certificates never expire
4. **TLS version**: nginx defaults to TLS 1.2 and 1.3
5. **HTTP → HTTPS redirect** enforced by certbot

## Support

For Let's Encrypt issues:
- Documentation: https://certbot.eff.org/
- Community: https://community.letsencrypt.org/

For infrastructure issues:
- Check `/var/log/user-data.log` on the EC2 instance
- Contact the infrastructure team
