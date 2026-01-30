#!/bin/bash
#
# Manual SSL Installation Script for Existing EC2 Instance
# This script installs Let's Encrypt SSL on the running instance WITHOUT recreating it
#
# Usage:
#   1. SSH to your EC2 instance
#   2. Copy this script to the instance
#   3. Run: sudo bash install_ssl_manual.sh dev.eqaya.com admin@eqaya.com
#

set -e

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

DOMAIN=${1:-dev.eqaya.com}
EMAIL=${2:-admin@eqaya.com}

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Installing SSL Certificate${NC}"
echo -e "${GREEN}Domain: ${DOMAIN}${NC}"
echo -e "${GREEN}Email: ${EMAIL}${NC}"
echo -e "${GREEN}========================================${NC}"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root (use sudo)${NC}"
   exit 1
fi

echo -e "${YELLOW}Step 1: Installing certbot...${NC}"
apt-get update -y
apt-get install -y certbot python3-certbot-nginx

echo -e "${YELLOW}Step 2: Backing up current nginx config...${NC}"
cp /etc/nginx/sites-available/app.conf /etc/nginx/sites-available/app.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || echo "No existing app.conf to backup"
cp /etc/nginx/conf.d/app.conf /etc/nginx/conf.d/app.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || echo "No existing conf.d/app.conf to backup"

echo -e "${YELLOW}Step 3: Updating nginx configuration for SSL...${NC}"

# Remove old config if exists
rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/app.conf

# Create new config with proper server_name
cat > /etc/nginx/sites-available/app.conf <<NGINX
server {
    listen 80;
    server_name ${DOMAIN};

    # ACME challenge location for Let's Encrypt
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /health {
        return 200 "OK";
        add_header Content-Type text/plain;
    }
}
NGINX

# Enable the site
ln -sf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf

echo -e "${YELLOW}Step 4: Testing nginx configuration...${NC}"
nginx -t

echo -e "${YELLOW}Step 5: Reloading nginx...${NC}"
systemctl reload nginx

echo -e "${YELLOW}Step 6: Creating certbot webroot directory...${NC}"
mkdir -p /var/www/certbot
chown -R www-data:www-data /var/www/certbot

echo -e "${YELLOW}Step 7: Verifying DNS resolution...${NC}"
RESOLVED_IP=$(dig +short ${DOMAIN} @8.8.8.8 | tail -n1)
INSTANCE_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4)

echo "Domain ${DOMAIN} resolves to: ${RESOLVED_IP}"
echo "This instance IP: ${INSTANCE_IP}"

if [ "${RESOLVED_IP}" != "${INSTANCE_IP}" ]; then
    echo -e "${RED}WARNING: DNS mismatch detected!${NC}"
    echo -e "${YELLOW}Domain ${DOMAIN} is not pointing to this instance.${NC}"
    echo -e "${YELLOW}Certificate request may fail. Continue anyway? (y/n)${NC}"
    read -r response
    if [[ ! "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        echo "Aborting..."
        exit 1
    fi
fi

echo -e "${YELLOW}Step 8: Requesting SSL certificate from Let's Encrypt...${NC}"
echo "This may take 1-2 minutes..."

certbot --nginx \
    -d ${DOMAIN} \
    --non-interactive \
    --agree-tos \
    --email ${EMAIL} \
    --redirect \
    --no-eff-email

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ SSL certificate successfully installed!${NC}"
else
    echo -e "${RED}✗ Certificate request failed!${NC}"
    echo "Check logs at /var/log/letsencrypt/letsencrypt.log"
    exit 1
fi

echo -e "${YELLOW}Step 9: Setting up auto-renewal...${NC}"

# Create cron job for auto-renewal
cat > /etc/cron.d/certbot-renew <<CRON
# Certbot renewal cron job - runs twice daily
0 0,12 * * * root certbot renew --quiet --nginx
CRON
chmod 644 /etc/cron.d/certbot-renew

# Create post-renewal hook
mkdir -p /etc/letsencrypt/renewal-hooks/post
cat > /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh <<HOOK
#!/bin/bash
systemctl reload nginx
HOOK
chmod +x /etc/letsencrypt/renewal-hooks/post/nginx-reload.sh

echo -e "${GREEN}✓ Auto-renewal configured (runs twice daily)${NC}"

echo -e "${YELLOW}Step 10: Verifying certificate...${NC}"
certbot certificates

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}SSL Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "Certificate Details:"
echo -e "  Domain: ${GREEN}${DOMAIN}${NC}"
echo -e "  Location: ${GREEN}/etc/letsencrypt/live/${DOMAIN}/${NC}"
echo -e "  Valid for: ${GREEN}90 days${NC}"
echo -e "  Auto-renewal: ${GREEN}Enabled (twice daily)${NC}"
echo ""
echo -e "Test your HTTPS connection:"
echo -e "  ${GREEN}curl https://${DOMAIN}/health${NC}"
echo ""
echo -e "Next renewal check: ${YELLOW}$(systemctl list-timers | grep certbot || echo 'Next cron run at midnight or noon')${NC}"
echo ""
echo -e "${YELLOW}Note: HTTP traffic is now automatically redirected to HTTPS${NC}"
echo ""
