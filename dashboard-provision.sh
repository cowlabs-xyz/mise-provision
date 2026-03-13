#!/bin/bash
# ============================================================================
# Mise Dashboard — Provisioning Add-on
# ============================================================================
# Run AFTER mise-provision.sh to add the web dashboard to a Mise VPS.
# Installs PostgreSQL, ClawdOS (rebranded Mise dashboard), and Caddy.
#
# Usage:
#   bash dashboard-provision.sh --config dashboard-config.json
#
# Config fields:
#   dashboard_domain    (required)  e.g. "marios-bistro.heymise.com"
#   dashboard_user      (required)  Login username for the dashboard
#   dashboard_password  (required)  Login password (min 8 chars)
#   restaurant_name     (required)  Restaurant name (for display)
#   gateway_token       (optional)  OpenClaw gateway token (reads from openclaw.env if not set)
#   openrouter_mgmt_key (optional)  OpenRouter management key (for usage tracking)
#   openrouter_key_hash (optional)  Restaurant's OpenRouter key hash
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STEP=0
TOTAL_STEPS=10

step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}[$STEP/$TOTAL_STEPS]${NC} $1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

ok() { echo -e "${GREEN}✓  $1${NC}"; }
warn() { echo -e "${YELLOW}⚠  $1${NC}"; }
fail() { echo -e "${RED}✗  $1${NC}"; exit 1; }

# ============================================================================
# PARSE CONFIG
# ============================================================================

CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        *) fail "Unknown option: $1" ;;
    esac
done

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    fail "Usage: bash dashboard-provision.sh --config dashboard-config.json"
fi

if ! command -v jq &>/dev/null; then
    apt-get install -y -qq jq >/dev/null 2>&1
fi

DASHBOARD_DOMAIN=$(jq -r '.dashboard_domain // empty' "$CONFIG_FILE")
DASHBOARD_USER=$(jq -r '.dashboard_user // empty' "$CONFIG_FILE")
DASHBOARD_PASSWORD=$(jq -r '.dashboard_password // empty' "$CONFIG_FILE")
RESTAURANT_NAME=$(jq -r '.restaurant_name // empty' "$CONFIG_FILE")
GATEWAY_TOKEN=$(jq -r '.gateway_token // empty' "$CONFIG_FILE")
OPENROUTER_MGMT_KEY=$(jq -r '.openrouter_mgmt_key // empty' "$CONFIG_FILE")
OPENROUTER_KEY_HASH=$(jq -r '.openrouter_key_hash // empty' "$CONFIG_FILE")
PLAN_SLUG=$(jq -r '.plan_slug // "starter"' "$CONFIG_FILE")
DASHBOARD_EMAIL=$(jq -r '.dashboard_email // empty' "$CONFIG_FILE")
RESEND_API_KEY=$(jq -r '.resend_api_key // empty' "$CONFIG_FILE")

[ -z "$DASHBOARD_DOMAIN" ] && fail "dashboard_domain is required"
[ -z "$DASHBOARD_USER" ] && fail "dashboard_user is required"
# Password OR email required (magic link auth doesn't need password)
if [ -z "$DASHBOARD_PASSWORD" ] && [ -z "$DASHBOARD_EMAIL" ]; then
    fail "dashboard_password or dashboard_email is required"
fi
if [ -n "$DASHBOARD_PASSWORD" ] && [ ${#DASHBOARD_PASSWORD} -lt 8 ]; then
    fail "dashboard_password must be at least 8 characters"
fi
[ -z "$RESTAURANT_NAME" ] && fail "restaurant_name is required"

# Try to get gateway token from openclaw.env if not in config
if [ -z "$GATEWAY_TOKEN" ] && [ -f /root/openclaw.env ]; then
    GATEWAY_TOKEN=$(grep OPENCLAW_GATEWAY_TOKEN /root/openclaw.env | cut -d= -f2)
fi
[ -z "$GATEWAY_TOKEN" ] && fail "gateway_token is required (or set OPENCLAW_GATEWAY_TOKEN in /root/openclaw.env)"

echo -e "${GREEN}🦞 Mise Dashboard Provisioning${NC}"
echo "  Domain: $DASHBOARD_DOMAIN"
echo "  User: $DASHBOARD_USER"
echo "  Restaurant: $RESTAURANT_NAME"
echo ""

# ============================================================================
# INSTALL POSTGRESQL
# ============================================================================

step "Installing PostgreSQL"
if command -v psql &>/dev/null; then
    ok "PostgreSQL already installed"
else
    apt-get install -y -qq postgresql postgresql-contrib >/dev/null 2>&1
    systemctl enable postgresql
    systemctl start postgresql
    ok "PostgreSQL installed and started"
fi

# Create database and user
step "Setting up database"
DB_PASSWORD=$(openssl rand -hex 16)
su - postgres -c "psql -c \"SELECT 1 FROM pg_roles WHERE rolname='mise_dashboard'\" | grep -q 1" 2>/dev/null && {
    ok "Database user already exists"
} || {
    su - postgres -c "psql -c \"CREATE USER mise_dashboard WITH PASSWORD '$DB_PASSWORD';\""
    su - postgres -c "psql -c \"CREATE DATABASE mise_dashboard OWNER mise_dashboard;\""
    ok "Database created: mise_dashboard"
}

DATABASE_URL="postgres://mise_dashboard:$DB_PASSWORD@localhost:5432/mise_dashboard"

# ============================================================================
# INSTALL DASHBOARD
# ============================================================================

step "Cloning Mise dashboard"
DASHBOARD_DIR="/opt/mise-dashboard"

# Set up deploy key for private repo access
DEPLOY_KEY="/root/.ssh/mise_deploy_key"
if [ -f "$DEPLOY_KEY" ]; then
    export GIT_SSH_COMMAND="ssh -i $DEPLOY_KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=no"
fi

if [ -d "$DASHBOARD_DIR" ]; then
    cd "$DASHBOARD_DIR" && git pull origin main 2>/dev/null || true
    ok "Dashboard updated"
else
    if [ -f "$DEPLOY_KEY" ]; then
        git clone --branch main --depth 1 \
            git@github.com:cowlabs-xyz/mise-dashboard.git "$DASHBOARD_DIR"
        ok "Dashboard cloned (private repo via deploy key)"
    else
        git clone --depth 1 https://github.com/hasanator3000/ClawdOS.git "$DASHBOARD_DIR"
        warn "No deploy key found — using upstream ClawdOS"
    fi
fi

step "Installing dependencies and building"
cd "$DASHBOARD_DIR"

# Generate secrets
SESSION_PASSWORD=$(openssl rand -base64 32)
CONSULT_TOKEN=$(openssl rand -base64 32)

# Create .env.local
cat > .env.local << ENVEOF
DATABASE_URL=$DATABASE_URL
SESSION_PASSWORD=$SESSION_PASSWORD
CLAWDOS_CONSULT_TOKEN=$CONSULT_TOKEN
CLAWDBOT_URL=http://127.0.0.1:18789
CLAWDBOT_TOKEN=$GATEWAY_TOKEN
APP_URL=https://$DASHBOARD_DOMAIN
OPENROUTER_MANAGEMENT_KEY=$OPENROUTER_MGMT_KEY
MISE_OPENROUTER_KEY_HASH=$OPENROUTER_KEY_HASH
MISE_PLAN_SLUG=$PLAN_SLUG
RESEND_API_KEY=$RESEND_API_KEY
ENVEOF
chmod 600 .env.local

npm ci --production=false 2>&1 | tail -3
npm run build 2>&1 | tail -5
ok "Dashboard built"

step "Running database migrations"
cd "$DASHBOARD_DIR"
DATABASE_URL="$DATABASE_URL" node scripts/migrate.mjs 2>&1 || warn "Migrations may need manual review"
ok "Migrations applied"

step "Creating dashboard user"
cd "$DASHBOARD_DIR"
EMAIL_FLAG=""
if [ -n "$DASHBOARD_EMAIL" ]; then
    EMAIL_FLAG="--email $DASHBOARD_EMAIL"
fi
if [ -n "$DASHBOARD_PASSWORD" ]; then
    DATABASE_URL="$DATABASE_URL" node scripts/create-user.mjs "$DASHBOARD_USER" "$DASHBOARD_PASSWORD" $EMAIL_FLAG 2>&1 || warn "User creation needs manual step"
else
    DATABASE_URL="$DATABASE_URL" node scripts/create-user.mjs "$DASHBOARD_USER" $EMAIL_FLAG 2>&1 || warn "User creation needs manual step"
fi
ok "Dashboard user configured"

# ============================================================================
# SYSTEMD SERVICE FOR DASHBOARD
# ============================================================================

step "Creating dashboard systemd service"
cat > /etc/systemd/system/mise-dashboard.service << SVCEOF
[Unit]
Description=Mise Dashboard ($RESTAURANT_NAME)
After=network-online.target postgresql.service openclaw.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$DASHBOARD_DIR
Environment=NODE_ENV=production
Environment=PORT=3000
EnvironmentFile=$DASHBOARD_DIR/.env.local
ExecStart=/usr/bin/node $DASHBOARD_DIR/node_modules/.bin/next start -H 127.0.0.1 -p 3000
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable mise-dashboard
systemctl start mise-dashboard
ok "Dashboard service started on port 3000"

# ============================================================================
# INSTALL CADDY (REVERSE PROXY + HTTPS)
# ============================================================================

step "Installing Caddy"
if command -v caddy &>/dev/null; then
    ok "Caddy already installed"
else
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq caddy >/dev/null 2>&1
    ok "Caddy installed"
fi

step "Configuring Caddy for $DASHBOARD_DOMAIN"
cat > /etc/caddy/Caddyfile << CADDYEOF
$DASHBOARD_DOMAIN {
    reverse_proxy 127.0.0.1:3000
    encode gzip
    
    header {
        X-Frame-Options "DENY"
        X-Content-Type-Options "nosniff"
        Referrer-Policy "strict-origin-when-cross-origin"
        -Server
    }
}
CADDYEOF

systemctl enable caddy
systemctl restart caddy
ok "Caddy configured — HTTPS at https://$DASHBOARD_DOMAIN"

# ============================================================================
# DONE
# ============================================================================

step "Verification"
sleep 3

if systemctl is-active --quiet mise-dashboard; then
    ok "Dashboard service: running"
else
    warn "Dashboard service: check logs with 'journalctl -u mise-dashboard -n 30'"
fi

if systemctl is-active --quiet caddy; then
    ok "Caddy: running"
else
    warn "Caddy: check logs with 'journalctl -u caddy -n 30'"
fi

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🦞 Dashboard deployed for $RESTAURANT_NAME!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Dashboard: https://$DASHBOARD_DOMAIN"
echo "  Login:     $DASHBOARD_USER / [password from config]"
echo ""
echo "  Services:"
echo "    Dashboard:  systemctl status mise-dashboard"
echo "    Caddy:      systemctl status caddy"
echo "    PostgreSQL: systemctl status postgresql"
echo "    OpenClaw:   systemctl status openclaw"
echo ""
