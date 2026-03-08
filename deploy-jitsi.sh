#!/bin/bash
set -e

# ============================================================
# Jitsi Meet Deployment Script (jitsicl)
# Deploys a complete Jitsi server with JWT auth, token_affiliation,
# teacher-presence middleware, and custom UI.
#
# Usage: ./deploy-jitsi.sh [OPTIONS]
#
# Options:
#   --ip <IP>           Public IP (auto-detected if not provided)
#   --secret <SECRET>   JWT secret (generated if not provided)
#   --domain <DOMAIN>   Domain name (enables nginx + Let's Encrypt SSL)
#   --email <EMAIL>     Email for Let's Encrypt (required with --domain)
#
# Examples:
#   ./deploy-jitsi.sh
#   ./deploy-jitsi.sh --domain jitsi.example.com --email admin@example.com
#   ./deploy-jitsi.sh --ip 1.2.3.4 --secret mysecret
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Parse arguments ---
PUBLIC_IP=""
JWT_SECRET=""
DOMAIN=""
LE_EMAIL=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip)      PUBLIC_IP="$2"; shift 2 ;;
        --secret)  JWT_SECRET="$2"; shift 2 ;;
        --domain)  DOMAIN="$2"; shift 2 ;;
        --email)   LE_EMAIL="$2"; shift 2 ;;
        *)
            # Legacy positional args: ./deploy-jitsi.sh [IP] [SECRET]
            if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP="$1"
            elif [ -z "$JWT_SECRET" ]; then JWT_SECRET="$1"
            fi
            shift ;;
    esac
done

# --- Config ---
GITHUB_ORG="rdarsej-cyber"
DEPLOY_DIR="$HOME/docker-jitsi-meet"
JITSI_SRC_DIR="$HOME/jitsi-meet-src"
CONFIG_DIR="$HOME/.jitsi-meet-cfg"
JWT_APP_ID="jitsicl"
NODE_VERSION="20"

# --- Auto-detect public IP ---
if [ -z "$PUBLIC_IP" ]; then
    PUBLIC_IP=$(curl -4 -s --connect-timeout 5 ifconfig.me || curl -4 -s --connect-timeout 5 api.ipify.org || echo "")
    if [ -z "$PUBLIC_IP" ]; then
        err "Could not detect public IP. Pass it with --ip <IP>"
    fi
    log "Detected public IP: $PUBLIC_IP"
fi

# --- Generate JWT secret if not provided ---
if [ -z "$JWT_SECRET" ]; then
    JWT_SECRET=$(openssl rand -hex 32)
    log "Generated JWT secret: $JWT_SECRET"
fi

# --- Validate domain options ---
if [ -n "$DOMAIN" ] && [ -z "$LE_EMAIL" ]; then
    err "When using --domain, you must also provide --email for Let's Encrypt"
fi

# ============================================================
# Step 1: Install dependencies
# ============================================================
log "Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq docker.io make git curl > /dev/null 2>&1

# Docker compose plugin
if ! docker compose version > /dev/null 2>&1; then
    log "Installing Docker Compose plugin..."
    mkdir -p ~/.docker/cli-plugins
    curl -SL -o ~/.docker/cli-plugins/docker-compose \
        https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)
    chmod +x ~/.docker/cli-plugins/docker-compose
fi

# Ensure current user can run docker
if ! docker ps > /dev/null 2>&1; then
    sudo usermod -aG docker "$USER"
    warn "Added $USER to docker group. If docker commands fail, log out and back in."
    sg docker -c "docker ps" > /dev/null 2>&1 || true
fi

log "Docker $(docker --version | grep -oP '\d+\.\d+\.\d+') | Compose $(docker compose version --short 2>/dev/null || echo 'N/A')"

# Node.js via nvm
if ! command -v node > /dev/null 2>&1; then
    log "Installing Node.js $NODE_VERSION via nvm..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash > /dev/null 2>&1
    fi
    . "$NVM_DIR/nvm.sh"
    nvm install $NODE_VERSION > /dev/null 2>&1
    nvm use $NODE_VERSION > /dev/null 2>&1
else
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
fi
log "Node.js $(node --version)"

# ============================================================
# Step 2: Clone repositories
# ============================================================
if [ -d "$DEPLOY_DIR" ]; then
    log "docker-jitsi-meet already exists, pulling latest..."
    cd "$DEPLOY_DIR" && git pull --ff-only origin master
else
    log "Cloning docker-jitsi-meet..."
    git clone "https://github.com/$GITHUB_ORG/docker-jitsi-meet.git" "$DEPLOY_DIR"
fi

if [ -d "$JITSI_SRC_DIR" ]; then
    log "jitsi-meet-src already exists, pulling latest..."
    cd "$JITSI_SRC_DIR" && git pull --ff-only origin master
else
    log "Cloning jitsi-meet (custom build)..."
    git clone "https://github.com/$GITHUB_ORG/jitsi-meet.git" "$JITSI_SRC_DIR"
fi

# ============================================================
# Step 3: Build custom Jitsi Meet
# ============================================================
log "Building custom Jitsi Meet (this may take a few minutes)..."
cd "$JITSI_SRC_DIR"
npm install --loglevel=error 2>&1 | tail -3
make 2>&1 | tail -3

if [ ! -f "libs/app.bundle.min.js" ]; then
    err "Build failed — libs/app.bundle.min.js not found"
fi
log "Jitsi Meet build complete ($(du -sh libs/ | cut -f1))"

# ============================================================
# Step 4: Configure docker-jitsi-meet
# ============================================================
cd "$DEPLOY_DIR"

# Fix mount paths to current user's home
sed -i "s|/root/jitsi-meet-src|$JITSI_SRC_DIR|g" docker-compose.yml
sed -i "s|/home/[^/]*/jitsi-meet-src|$JITSI_SRC_DIR|g" docker-compose.yml

# Create .env from template
if [ ! -f .env ]; then
    cp env.example .env
fi

# Generate passwords
JICOFO_PASS=$(openssl rand -hex 16)
JVB_PASS=$(openssl rand -hex 16)

# Apply settings
sed -i "s|^#ENABLE_AUTH=.*|ENABLE_AUTH=1|" .env
sed -i "s|^#AUTH_TYPE=.*|AUTH_TYPE=jwt|" .env
sed -i "s|^#JWT_APP_ID=.*|JWT_APP_ID=$JWT_APP_ID|" .env
sed -i "s|^#JWT_APP_SECRET=.*|JWT_APP_SECRET=$JWT_SECRET|" .env
sed -i "s|^JICOFO_AUTH_PASSWORD=.*|JICOFO_AUTH_PASSWORD=$JICOFO_PASS|" .env
sed -i "s|^JVB_AUTH_PASSWORD=.*|JVB_AUTH_PASSWORD=$JVB_PASS|" .env

# Jitsi listens on 8000/8443 internally; nginx handles 80/443 if domain is set
sed -i "s|^HTTP_PORT=.*|HTTP_PORT=8000|" .env
sed -i "s|^HTTPS_PORT=.*|HTTPS_PORT=8443|" .env

if [ -n "$DOMAIN" ]; then
    sed -i "s|^#PUBLIC_URL=.*|PUBLIC_URL=https://$DOMAIN|" .env
    sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL=https://$DOMAIN|" .env
fi

# Append custom settings if not already present
grep -q "^ENABLE_P2P=" .env || echo "ENABLE_P2P=false" >> .env
grep -q "^JWT_ALLOW_EMPTY=" .env || echo "JWT_ALLOW_EMPTY=0" >> .env
grep -q "^ENABLE_AUTO_OWNER=" .env || echo "ENABLE_AUTO_OWNER=true" >> .env
grep -q "^ENABLE_AV_MODERATION=" .env || echo "ENABLE_AV_MODERATION=false" >> .env
grep -q "^JVB_ADVERTISE_IPS=" .env || echo "JVB_ADVERTISE_IPS=$PUBLIC_IP" >> .env

log "Configured .env (JWT_APP_ID=$JWT_APP_ID, PUBLIC_IP=$PUBLIC_IP)"

# ============================================================
# Step 5: Create config directories and copy plugins
# ============================================================
mkdir -p "$CONFIG_DIR"/{web,transcripts,prosody/config,prosody/prosody-plugins-custom,jicofo,jvb,jigasi,jibri}
cp "$DEPLOY_DIR"/prosody/prosody-plugins-custom/*.lua "$CONFIG_DIR/prosody/prosody-plugins-custom/"
log "Config directories created, custom Prosody plugins copied"

# ============================================================
# Step 6: Build and start services
# ============================================================
log "Building custom Prosody image..."
docker compose build prosody 2>&1 | tail -3

log "Starting all services..."
docker compose up -d 2>&1 | tail -10

# Wait for services to be ready
log "Waiting for services to initialize..."
sleep 10

# Verify all containers are running
RUNNING=$(docker compose ps --format json 2>/dev/null | grep -c '"running"' || docker compose ps | grep -c "Up")
EXPECTED=4

if [ "$RUNNING" -ge "$EXPECTED" ]; then
    log "All $RUNNING/$EXPECTED containers running"
else
    warn "Only $RUNNING/$EXPECTED containers running. Check: docker compose ps"
fi

# Disable welcome page
if [ -f "$CONFIG_DIR/web/config.js" ]; then
    grep -q "enableWelcomePage" "$CONFIG_DIR/web/config.js" || {
        echo 'config.enableWelcomePage = false;' >> "$CONFIG_DIR/web/config.js"
        echo 'config.enableClosePage = false;' >> "$CONFIG_DIR/web/config.js"
        docker compose restart web > /dev/null 2>&1
        log "Welcome page disabled"
    }
else
    warn "config.js not yet generated — welcome page will be disabled on next run"
fi

# ============================================================
# Step 7: Setup nginx + Let's Encrypt (if domain provided)
# ============================================================
if [ -n "$DOMAIN" ]; then
    log "Setting up nginx reverse proxy with SSL for $DOMAIN..."

    sudo apt-get install -y -qq nginx certbot python3-certbot-nginx > /dev/null 2>&1

    # Create nginx config
    sudo tee /etc/nginx/sites-available/"$DOMAIN" > /dev/null << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /xmpp-websocket {
        proxy_pass http://127.0.0.1:8000/xmpp-websocket;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    location /colibri-ws {
        proxy_pass http://127.0.0.1:8000/colibri-ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
    }

    location /http-bind {
        proxy_pass http://127.0.0.1:8000/http-bind;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINXEOF

    sudo ln -sf /etc/nginx/sites-available/"$DOMAIN" /etc/nginx/sites-enabled/
    sudo nginx -t && sudo systemctl reload nginx
    log "Nginx configured for $DOMAIN"

    # Get Let's Encrypt certificate
    log "Requesting Let's Encrypt certificate..."
    if sudo certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect; then
        log "SSL certificate obtained and configured!"
        SERVER_URL="https://$DOMAIN"
    else
        warn "Let's Encrypt failed — ensure ports 80 and 443 are open in your firewall"
        warn "Re-run: sudo certbot --nginx -d $DOMAIN"
        SERVER_URL="http://$PUBLIC_IP:8000"
    fi
else
    SERVER_URL="https://$PUBLIC_IP:8443"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "============================================================"
echo -e "${GREEN}Jitsi Meet deployment complete!${NC}"
echo "============================================================"
echo ""
echo "Server IP:      $PUBLIC_IP"
if [ -n "$DOMAIN" ]; then
echo "Domain:         $DOMAIN"
echo "Web URL:        https://$DOMAIN"
else
echo "Web HTTPS:      https://$PUBLIC_IP:8443"
echo "Web HTTP:       http://$PUBLIC_IP:8000"
fi
echo "JVB Media:      UDP port 10000"
echo ""
echo "JWT App ID:     $JWT_APP_ID"
echo "JWT Secret:     $JWT_SECRET"
echo ""
echo "============================================================"
echo -e "${YELLOW}IMPORTANT: Ensure these ports are open in your firewall:${NC}"
if [ -n "$DOMAIN" ]; then
echo "  - TCP 80    (HTTP / Let's Encrypt renewal)"
echo "  - TCP 443   (HTTPS)"
else
echo "  - TCP 8443  (HTTPS web interface)"
echo "  - TCP 8000  (HTTP web interface)"
fi
echo "  - UDP 10000 (JVB media traffic)"
echo ""
echo -e "${YELLOW}Moodle Plugin Configuration:${NC}"
echo "  Server URL:   $SERVER_URL"
echo "  App ID:       $JWT_APP_ID"
echo "  App Secret:   $JWT_SECRET"
echo "============================================================"
echo ""
echo "To re-run after code changes:  cd $DEPLOY_DIR && docker compose up -d"
echo "To view logs:                  cd $DEPLOY_DIR && docker compose logs -f"
if [ -n "$DOMAIN" ]; then
echo "To renew SSL cert:             sudo certbot renew"
fi
echo "To disable welcome page:       Re-run this script after first start"
