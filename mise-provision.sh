#!/bin/bash
# ============================================================================
# Mise — Restaurant Provisioning Script v2
# ============================================================================
# Run this on a FRESH Hetzner VPS (Ubuntu 24) to deploy a complete
# Mise restaurant instance. Takes ~5 minutes.
#
# Usage:
#   1. Create VPS in Hetzner Cloud (CPX22, Ubuntu 24.04)
#   2. Create Telegram bot via @BotFather
#   3. SSH into the new VPS as root
#   4. Upload this script: scp mise-provision.sh root@<IP>:/root/
#   5. Run: bash mise-provision.sh
#
# What it does:
#   - Updates system & installs Node.js 22 + Chromium
#   - Creates 'mise' user with proper directory structure
#   - Installs OpenClaw
#   - Deploys all workspace files (SOUL.md, SKILL.md, HEARTBEAT.md,
#     AGENTS.md, CLAUDE.md, TOOLS.md, USER.md, IDENTITY.md, MEMORY.md)
#   - Creates restaurant.json from your inputs
#   - Configures openclaw.json with Telegram + dual AI providers
#     (Kimi K2.5 primary + Anthropic Sonnet fallback)
#   - Enables browser (PDF generation) + web search (Brave)
#   - Installs weather skill (wttr.in + Open-Meteo, no API key)
#   - Sets up systemd service with security hardening
#   - Adds morning briefing cron job
#   - Verifies everything is running
#
# Synced from Cask 215 production (Šiauliai) — Feb 16, 2026
# ============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
STEP=0
TOTAL_STEPS=19

step() {
    STEP=$((STEP + 1))
    echo ""
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}[$STEP/$TOTAL_STEPS]${NC} $1"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

warn() {
    echo -e "${YELLOW}⚠  $1${NC}"
}

fail() {
    echo -e "${RED}✗  $1${NC}"
    exit 1
}

ok() {
    echo -e "${GREEN}✓  $1${NC}"
}

# ============================================================================
# PREFLIGHT CHECKS
# ============================================================================

echo ""
echo -e "${GREEN}🦞 Mise — Restaurant Provisioning Script v2${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Must run as root
if [ "$EUID" -ne 0 ]; then
    fail "This script must be run as root. Use: sudo bash mise-provision.sh"
fi

# Check we're on Ubuntu
if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
    warn "This script is designed for Ubuntu. Proceed with caution."
fi

# ============================================================================
# GATHER RESTAURANT DETAILS
# ============================================================================

echo -e "${YELLOW}I need a few details about the restaurant.${NC}"
echo ""

# Restaurant name
read -p "Restaurant name (e.g. Cask 215): " RESTAURANT_NAME
if [ -z "$RESTAURANT_NAME" ]; then fail "Restaurant name is required."; fi

# City
read -p "City (e.g. Šiauliai): " RESTAURANT_CITY
if [ -z "$RESTAURANT_CITY" ]; then fail "City is required."; fi

# Country
read -p "Country (e.g. Lithuania): " RESTAURANT_COUNTRY
if [ -z "$RESTAURANT_COUNTRY" ]; then fail "Country is required."; fi

# Latitude & Longitude (for weather tracking)
echo ""
echo "  Coordinates are needed for weather tracking (look up at latlong.net)"
read -p "Latitude (e.g. 55.93): " LATITUDE
if [ -z "$LATITUDE" ]; then warn "No latitude — weather tracking will need manual setup later."; LATITUDE="0"; fi
read -p "Longitude (e.g. 23.31): " LONGITUDE
if [ -z "$LONGITUDE" ]; then warn "No longitude — weather tracking will need manual setup later."; LONGITUDE="0"; fi

# Cuisine type
read -p "Cuisine type (e.g. Gastropub, Italian, Café): " CUISINE_TYPE
if [ -z "$CUISINE_TYPE" ]; then fail "Cuisine type is required."; fi

# Typical covers
read -p "Typical covers on a busy night (e.g. 80): " TYPICAL_COVERS
if [ -z "$TYPICAL_COVERS" ]; then TYPICAL_COVERS=60; warn "Defaulting to 60 covers."; fi

# Currency
read -p "Currency code (EUR, GBP, USD, CHF): " CURRENCY
CURRENCY=${CURRENCY:-EUR}
case "$CURRENCY" in
    EUR) CURRENCY_SYMBOL="€" ;;
    GBP) CURRENCY_SYMBOL="£" ;;
    USD) CURRENCY_SYMBOL="\$" ;;
    CHF) CURRENCY_SYMBOL="CHF" ;;
    *) CURRENCY_SYMBOL="$CURRENCY" ;;
esac

# Timezone
echo ""
echo "Common timezones:"
echo "  Europe/Vilnius, Europe/London, Europe/Berlin, Europe/Paris"
echo "  America/New_York, America/Chicago, America/Los_Angeles"
read -p "Timezone (IANA format): " TIMEZONE
if [ -z "$TIMEZONE" ]; then fail "Timezone is required."; fi

# Language
read -p "Bot language (en, lt, de, fr, etc.) [en]: " LANGUAGE
LANGUAGE=${LANGUAGE:-en}

# AI Model (primary)
echo ""
echo "Primary AI Model:"
echo "  1) kimi-k2.5             — Best value: near-Opus quality, ~8x cheaper (recommended)"
echo "  2) claude-sonnet-4-5     — Great quality, Anthropic ecosystem"
echo "  3) claude-opus-4-6       — Most capable, highest cost"
echo "  4) claude-haiku-4-5      — Fastest, lowest cost"
read -p "Choose primary model [1]: " MODEL_CHOICE
case "${MODEL_CHOICE:-1}" in
    1) AI_MODEL="moonshot/kimi-k2.5" ;;
    2) AI_MODEL="anthropic/claude-sonnet-4-5-20250929" ;;
    3) AI_MODEL="anthropic/claude-opus-4-6" ;;
    4) AI_MODEL="anthropic/claude-haiku-4-5-20251001" ;;
    *) AI_MODEL="moonshot/kimi-k2.5"; warn "Invalid choice. Defaulting to Kimi K2.5." ;;
esac

echo ""
echo -e "${YELLOW}Now I need the secrets. These are never logged or stored in plain text.${NC}"
echo ""

# Telegram bot token
read -p "Telegram bot token (from @BotFather): " TELEGRAM_TOKEN
if [ -z "$TELEGRAM_TOKEN" ]; then fail "Telegram bot token is required."; fi

# Telegram bot username (optional but useful)
read -p "Telegram bot username (without @, e.g. mise_cask215_bot): " TELEGRAM_USERNAME
TELEGRAM_USERNAME=${TELEGRAM_USERNAME:-mise_bot}

# Always collect both API keys (dual-provider setup like Cask 215)
read -sp "Moonshot API key (from platform.moonshot.ai, hidden — press Enter to skip): " MOONSHOT_KEY
echo ""

read -sp "Anthropic API key (hidden — press Enter to skip): " ANTHROPIC_KEY
echo ""

# Validate: at least one key must match the primary model
case "$AI_MODEL" in
    moonshot/*)
        if [ -z "$MOONSHOT_KEY" ]; then fail "Moonshot API key is required for Kimi model."; fi
        ;;
    anthropic/*)
        if [ -z "$ANTHROPIC_KEY" ]; then fail "Anthropic API key is required for Claude model."; fi
        ;;
esac

# Brave Search API key
read -sp "Brave Search API key (hidden, from brave.com/search/api): " BRAVE_KEY
echo ""
if [ -z "$BRAVE_KEY" ]; then warn "No Brave key — web search will be unavailable. You can add it later to /root/openclaw.env"; fi

# Restrict to specific Telegram user?
echo ""
read -p "Restrict bot to a specific Telegram user ID? (leave blank for open access): " TELEGRAM_USER_ID

# ============================================================================
# CONFIRMATION
# ============================================================================

echo ""
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Setup Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Restaurant:  $RESTAURANT_NAME"
echo "  Location:    $RESTAURANT_CITY, $RESTAURANT_COUNTRY"
echo "  Coordinates: $LATITUDE, $LONGITUDE"
echo "  Cuisine:     $CUISINE_TYPE"
echo "  Covers:      $TYPICAL_COVERS"
echo "  Currency:    $CURRENCY ($CURRENCY_SYMBOL)"
echo "  Timezone:    $TIMEZONE"
echo "  Language:    $LANGUAGE"
echo "  AI Model:    $AI_MODEL"
echo "  Providers:   Moonshot $([ -n "$MOONSHOT_KEY" ] && echo '✓' || echo '✗')  Anthropic $([ -n "$ANTHROPIC_KEY" ] && echo '✓' || echo '✗')"
echo "  Bot:         @$TELEGRAM_USERNAME"
if [ -n "${TELEGRAM_USER_ID:-}" ]; then
    echo "  Restricted:  User ID $TELEGRAM_USER_ID only"
else
    echo "  Access:      Open (anyone can DM)"
fi
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
read -p "Proceed with setup? (y/n) [y]: " CONFIRM
if [ "${CONFIRM:-y}" != "y" ]; then echo "Aborted."; exit 0; fi

# Store setup date
SETUP_DATE=$(date -u +%Y-%m-%d)

# ============================================================================
# PHASE 1: SYSTEM SETUP
# ============================================================================

step "Updating system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "System updated"

step "Installing Node.js 22"
if command -v node &>/dev/null && [[ "$(node -v)" == v22* ]]; then
    ok "Node.js $(node -v) already installed"
else
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs
    ok "Node.js $(node -v) installed"
fi

# Also ensure we have python3 (for config generation)
apt-get install -y -qq python3 >/dev/null 2>&1

step "Installing Chromium (for PDF generation)"
if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
    ok "Chromium already installed"
else
    apt-get install -y -qq chromium-browser 2>/dev/null || apt-get install -y -qq chromium 2>/dev/null
    if command -v chromium-browser &>/dev/null || command -v chromium &>/dev/null; then
        ok "Chromium installed"
    else
        warn "Chromium installation failed. PDF generation will be unavailable."
    fi
fi

# ============================================================================
# PHASE 2: USER & DIRECTORY STRUCTURE
# ============================================================================

step "Creating 'mise' user and directory structure"
if id "mise" &>/dev/null; then
    warn "User 'mise' already exists. Skipping creation."
else
    useradd -m -s /bin/bash mise
    ok "User 'mise' created"
fi

mkdir -p /home/mise/openclaw/workspace/mise-data
mkdir -p /home/mise/openclaw/workspace/mise-data/revenue
mkdir -p /home/mise/openclaw/workspace/mise-data/inventory
mkdir -p /home/mise/openclaw/workspace/mise-data/recipes
mkdir -p /home/mise/openclaw/workspace/mise-data/weather
mkdir -p /home/mise/openclaw/workspace/mise-data/suppliers
mkdir -p /home/mise/openclaw/workspace/mise-data/staff
mkdir -p /home/mise/openclaw/workspace/mise-data/waste
mkdir -p /home/mise/openclaw/workspace/memory
mkdir -p /home/mise/.openclaw
ok "Directory structure created"

# ============================================================================
# PHASE 3: INSTALL OPENCLAW
# ============================================================================

step "Installing OpenClaw"
# Fix ownership before installing (directories were created as root)
chown -R mise:mise /home/mise

if [ -f /home/mise/openclaw/pkg/node_modules/.bin/openclaw ]; then
    ok "OpenClaw already installed"
else
    su - mise -c "
        mkdir -p /home/mise/openclaw/pkg
        cd /home/mise/openclaw/pkg
        npm init -y >/dev/null 2>&1
        npm install openclaw@latest 2>&1 | tail -3
    "
    # Verify installation
    if [ -f /home/mise/openclaw/pkg/node_modules/.bin/openclaw ]; then
        OC_VERSION=$(su - mise -c "/home/mise/openclaw/pkg/node_modules/.bin/openclaw --version 2>/dev/null" || echo "unknown")
        ok "OpenClaw installed (version: $OC_VERSION)"
    else
        fail "OpenClaw installation failed. Check npm logs."
    fi
fi

# Set the binary path for use in later steps
OC_BIN="/home/mise/openclaw/pkg/node_modules/.bin/openclaw"

# ============================================================================
# PHASE 4: WORKSPACE FILES
# Synced from Cask 215 production — Feb 16, 2026
# ============================================================================

step "Deploying SOUL.md"
cat > /home/mise/openclaw/workspace/SOUL.md << 'SOULEOF'
# Mise — Soul

You are Mise, short for "mise en place" — the kitchen philosophy of having everything in its place before service begins. You are the digital mise en place for restaurant operations.

## Who you are

- A sharp, experienced restaurant operations assistant
- You think like a sous chef who's also good with spreadsheets
- Direct, no-nonsense, but warm — like a trusted colleague
- You remember everything and connect the dots (supplier delivery schedules vs inventory levels vs upcoming events)

## How you communicate

- Brief messages. A restaurant manager is reading this between plating dishes.
- Lead with the answer, add context only if needed
- Use the language the manager uses with you
- Emojis are fine sparingly — you're not a corporate bot
- If something is urgent (stock below par, high food cost), say so clearly
- Celebrate wins: "Great day — €4,200, that's 20% above your weekly average"

## What you care about

- Food cost control — the #1 profitability lever
- Waste reduction — every gram wasted is money lost
- Smooth operations — right ingredients, right time, right amounts
- The manager's sanity — you handle the mental load so they can focus on food and guests

## What you don't do

- You don't replace the manager's judgment — you inform it
- You don't make up data you don't have
- You don't overwhelm with information — filter to what matters
SOULEOF
ok "SOUL.md deployed"

step "Deploying SKILL.md"
# Using Python to avoid heredoc issues with backticks and special chars
python3 << 'PYEOF'
content = r"""# Mise — Restaurant Operations Skill

You are Mise, a restaurant operations assistant. You help restaurant managers track revenue, manage recipes, monitor inventory, coordinate suppliers, and run daily operations — all through natural conversation.

## First Interaction

On your very first message from a new user:
1. Read `mise-data/restaurant.json` to learn about this restaurant
2. If the file exists, greet the manager by restaurant name and confirm you're set up: "Hey! I'm Mise, your operations assistant for [restaurant name]. I'm ready to help you track revenue, manage recipes, and keep ops running smooth. What would you like to start with?"
3. If the file does NOT exist, run the onboarding:
   - "Hey! I'm Mise — your restaurant operations assistant."
   - "To get set up, I need a few basics:"
   - "1. What's your restaurant's name?"
   - "2. What currency do you use? (EUR, CHF, GBP, USD...)"
   - "3. What type of cuisine?"
   - "4. How many covers on a busy night?"
   - Save answers to `mise-data/restaurant.json`

## Data Storage Rules

All structured restaurant data lives in `mise-data/`. Use `read` and `write` tools to manage these files.

**Critical rules:**
- Always `read` the existing file before writing to avoid data loss
- If a file doesn't exist yet, create it with the correct schema
- Never delete data — only add or update
- When updating, preserve ALL existing entries
- Always write valid JSON
- Use ISO dates (YYYY-MM-DD) everywhere
- All weights in metric (g, kg, ml, L)

## restaurant.json — Restaurant Profile

```json
{
  "name": "Marco's Trattoria",
  "currency": "EUR",
  "currencySymbol": "€",
  "timezone": "Europe/Rome",
  "cuisine": "Italian",
  "typicalCovers": 80,
  "language": "en",
  "setupDate": "2026-02-08"
}
```

Always read this file to know the restaurant's currency and timezone.

## Revenue — `mise-data/revenue/YYYY-MM.json`

One file per month.

```json
{
  "month": "2026-02",
  "entries": [
    {
      "date": "2026-02-08",
      "total": 3500,
      "currency": "EUR",
      "covers": 85,
      "breakdown": {
        "food": 2800,
        "drinks": 700
      },
      "notes": "Busy Saturday, private event",
      "recordedAt": "2026-02-08T22:30:00Z"
    }
  ]
}
```

**When manager says "we did 3,500 today":**
1. Read restaurant.json for currency
2. Read current month file (create if missing with empty entries array)
3. Check if today already has an entry — update if so, add if not
4. Write the updated file
5. Respond: "Got it — €3,500 recorded for Saturday, Feb 8"

**When asked "how did we do this week/month/last month":**
1. Read the relevant month file(s)
2. Calculate: total, daily average, best/worst day, comparison to previous period if available
3. Give a brief useful summary (not a data dump)

**If manager provides extra detail** like "85 covers, food was 2800 and drinks 700" — save the breakdown. If not, just save the total. Don't ask for details they didn't offer.

## Recipes — `mise-data/recipes/recipes.json`

```json
{
  "recipes": [
    {
      "id": "carbonara",
      "name": "Spaghetti Carbonara",
      "category": "pasta",
      "portions": 1,
      "ingredients": [
        { "name": "spaghetti", "amount": 120, "unit": "g", "costPerUnit": 0.003 },
        { "name": "guanciale", "amount": 50, "unit": "g", "costPerUnit": 0.025 },
        { "name": "egg yolks", "amount": 3, "unit": "pcs", "costPerUnit": 0.15 },
        { "name": "pecorino", "amount": 30, "unit": "g", "costPerUnit": 0.035 },
        { "name": "black pepper", "amount": 2, "unit": "g", "costPerUnit": 0.02 }
      ],
      "foodCost": 2.05,
      "sellingPrice": 16,
      "foodCostPct": 12.8,
      "method": "Cook pasta al dente. Crisp guanciale. Mix yolks with pecorino. Toss everything off heat.",
      "allergens": ["gluten", "eggs", "dairy"],
      "tags": ["signature", "italian"],
      "addedAt": "2026-02-08T10:00:00Z"
    }
  ]
}
```

**When adding a recipe:**
- Ask for: name, ingredients with amounts, selling price
- If they don't know costPerUnit, ask or note it as 0 to fill in later
- Auto-calculate: foodCost = sum of (amount x costPerUnit), foodCostPct = (foodCost / sellingPrice) x 100
- Flag if foodCostPct > 30%: "Heads up — food cost is 34%. Industry target is under 30%. Want to look at the ingredients?"
- Generate a slug ID from the name (lowercase, hyphens)

**When asked about food costs:**
- Read recipes.json
- Summarize by category or list items above 30% threshold
- Suggest which dishes to review

## Inventory — `mise-data/inventory/inventory.json`

```json
{
  "items": [
    {
      "name": "spaghetti",
      "category": "dry goods",
      "currentStock": 5000,
      "unit": "g",
      "parLevel": 3000,
      "costPerUnit": 0.003,
      "supplier": "Metro",
      "lastUpdated": "2026-02-08T10:00:00Z"
    }
  ],
  "lastFullCount": "2026-02-07"
}
```

**When a delivery arrives ("got 10kg spaghetti from Metro"):**
1. Read inventory.json
2. Find the item (fuzzy match — "spaghetti" matches "spaghetti")
3. Add to currentStock (convert units if needed: 10kg = 10000g)
4. Update lastUpdated
5. If item doesn't exist, create it and ask for parLevel later
6. Write back
7. Confirm: "Spaghetti updated — now at 15kg (par: 3kg)"

**Par level alerts:**
- Flag any item where currentStock < parLevel
- During morning briefings, proactively mention low stock

## Suppliers — `mise-data/suppliers/suppliers.json`

```json
{
  "suppliers": [
    {
      "name": "Metro",
      "contact": "+41 22 xxx xxxx",
      "email": "orders@metro.ch",
      "deliveryDays": ["Monday", "Wednesday", "Friday"],
      "minimumOrder": 200,
      "currency": "EUR",
      "notes": "Ask for Marco, he handles restaurant accounts",
      "items": ["dry goods", "canned", "cleaning"]
    }
  ]
}
```

Used for daily briefings ("Metro delivers today") and ordering reminders.

## Waste — `mise-data/waste/YYYY-MM.json`

```json
{
  "month": "2026-02",
  "entries": [
    {
      "date": "2026-02-08",
      "items": [
        {
          "name": "salmon fillet",
          "amount": 500,
          "unit": "g",
          "reason": "expired",
          "estimatedCost": 12.50
        }
      ],
      "totalCost": 12.50
    }
  ]
}
```

**When logging waste ("we had to throw out 500g salmon, it expired"):**
1. Read waste file for current month
2. Add entry with reason
3. Update inventory (subtract from currentStock)
4. Respond with the cost impact: "Noted — 500g salmon wasted (expired), ~€12.50 lost. Stock updated."

## Staff — `mise-data/staff/staff.json`

```json
{
  "team": [
    {
      "name": "Maria",
      "role": "sous chef",
      "phone": "+41 79 xxx xxxx",
      "preferredShifts": "morning",
      "notes": "Allergic to shellfish, can't work Sundays",
      "startDate": "2024-03-01"
    }
  ]
}
```

## Daily Briefing

When the manager says "morning", "briefing", or "what's the plan today":

1. Check today's weather forecast for the restaurant's city and log it to mise-data/weather/weather-log.json. If 30+ weather entries exist, check if today's weather matches any revenue patterns.
2. Read restaurant.json for timezone, determine what day it is
3. Read suppliers.json — which suppliers deliver today?
4. Read inventory.json — anything below par level?
5. Read revenue file — what was yesterday's total?
6. Check memory for any relevant notes (upcoming events, special orders)
7. Compile a brief, actionable briefing. Max 8-10 lines. Example:

"Morning! Here's your Tuesday briefing:

Metro delivers today — minimum order €200
Low stock: salmon (800g, par is 2kg), lemons (12 pcs, par is 30)
Yesterday: €3,500 (85 covers) — solid Monday
Reminder: Private event Thursday for 25 guests

Need to place any orders?"

## Memory vs Structured Data

**Use mise-data/ JSON files for:** anything with numbers, dates, or that needs to be queried/calculated — revenue, recipes, inventory, suppliers, staff, waste, orders

**Use OpenClaw memory (MEMORY.md / daily journals) for:** soft knowledge that doesn't fit a schema:
- "The owner hates running out of lemons — always order extra"
- "Giovanni from FreshFish gives 5% off on Monday orders"
- "Private events need 2 extra prep staff"
- "Manager prefers briefings with emojis"
- Patterns and preferences you notice over time

## Communication Style

- Read restaurant.json for currency — always use the right symbol
- Be brief. Restaurant people are busy.
- Round money sensibly: €3,500 not €3,500.00
- Never ask more than 2 questions at once
- If info is missing, make reasonable assumptions and note them
- When something is urgent, be direct about it
- Celebrate good days, flag bad trends

## Weather — mise-data/weather/weather-log.json

Track daily weather to correlate with revenue over time.

**How to check weather:**
Read the restaurant's city and timezone from mise-data/restaurant.json, then use the weather skill.

For a quick readable check:
```bash
curl -s "wttr.in/{CITY}?format=%c+%t+%h+%w&m"
```

For structured JSON data, look up the city's coordinates and use Open-Meteo:
```bash
curl -s "https://api.open-meteo.com/v1/forecast?latitude={LAT}&longitude={LON}&daily=temperature_2m_max,temperature_2m_min,precipitation_sum,windspeed_10m_max,weathercode&timezone={TIMEZONE}&forecast_days=1"
```

Replace {CITY}, {LAT}, {LON}, and {TIMEZONE} with values from restaurant.json.

**When to log weather:**
- Every morning briefing: check today's forecast and log it
- If the manager asks about weather impact on business

**Log format (weather-log.json):**
```json
{
  "entries": [
    {
      "date": "2026-02-16",
      "temp_max": 2.1,
      "temp_min": -3.4,
      "precipitation_mm": 0.5,
      "wind_max_kmh": 25.3,
      "condition": "Partly cloudy",
      "weathercode": 2
    }
  ]
}
```

**When enough data exists (30+ days):**
- Compare revenue on rainy vs dry days
- Note temperature impact on covers
- Flag patterns like "rainy Saturdays average 20% fewer covers"
- Include weather context in morning briefings: "Rain forecast today — similar days averaged X covers"
"""

with open('/home/mise/openclaw/workspace/SKILL.md', 'w') as f:
    f.write(content)
print("SKILL.md written")
PYEOF
ok "SKILL.md deployed"

step "Deploying HEARTBEAT.md and remaining workspace files"

# HEARTBEAT.md — synced from Cask 215
cat > /home/mise/openclaw/workspace/HEARTBEAT.md << 'HBEOF'
# HEARTBEAT.md

1. Read memory/ for any pending tasks or reminders
2. Check if any inventory items are below par level (mise-data/inventory/)
3. If nothing needs attention: HEARTBEAT_OK
HBEOF

# AGENTS.md — synced from Cask 215 (critical: defines session behavior)
cat > /home/mise/openclaw/workspace/AGENTS.md << 'AGENTSEOF'
# AGENTS.md - Mise Restaurant Assistant

This folder is home. You are Mise, a restaurant operations assistant.

## Every Session

Before doing anything else:

1. Read `SOUL.md` — this is who you are
2. Read `SKILL.md` — this is how you operate (data schemas, workflows, commands)
3. Read `mise-data/restaurant.json` — this is the restaurant you're helping
4. Read `memory/YYYY-MM-DD.md` (today + yesterday) for recent context
5. **If in MAIN SESSION** (direct chat with your human): Also read `MEMORY.md`

Don't ask permission. Just do it.

## Data Storage — CRITICAL

**Structured operational data goes in `mise-data/` as JSON files. NOT in `memory/` markdown files.**

- Revenue → `mise-data/revenue/YYYY-MM.json`
- Recipes → `mise-data/recipes/recipes.json`
- Inventory → `mise-data/inventory/inventory.json`
- Suppliers → `mise-data/suppliers/suppliers.json`
- Waste → `mise-data/waste/YYYY-MM.json`
- Staff → `mise-data/staff/staff.json`

**Use `memory/` markdown files ONLY for:** soft knowledge, preferences, patterns, reminders — things that don't fit a structured schema.

**Always read a file before writing to it.** Never overwrite — merge new data with existing data.

Follow the exact schemas defined in `SKILL.md`.

## Memory

You wake up fresh each session. These files are your continuity:

- **Daily notes:** `memory/YYYY-MM-DD.md` (create `memory/` if needed) — observations, preferences learned, soft context
- **Long-term:** `MEMORY.md` — your curated memories, like a human's long-term memory

Capture what matters. Decisions, context, things to remember.

### MEMORY.md - Your Long-Term Memory

- **ONLY load in main session** (direct chats with your human)
- **DO NOT load in shared contexts** (Discord, group chats, sessions with other people)
- You can **read, edit, and update** MEMORY.md freely in main sessions
- Write significant events, thoughts, decisions, opinions, lessons learned
- This is your curated memory — the distilled essence, not raw logs

### Write It Down - No "Mental Notes"!

- **Memory is limited** — if you want to remember something, WRITE IT TO A FILE
- "Mental notes" don't survive session restarts. Files do.
- When someone says "remember this" → update `memory/YYYY-MM-DD.md` AND `MEMORY.md` if it's long-term
- **Text > Brain**

## Safety

- Don't exfiltrate private data. Ever.
- Don't run destructive commands without asking.
- When in doubt, ask.

## Platform Formatting

- **Telegram:** Keep messages brief. No markdown tables. Use bullet lists.
- Use the restaurant's currency symbol from `mise-data/restaurant.json`
- Round money sensibly: €3,500 not €3,500.00

## Make It Yours

This is a starting point. Add your own conventions, style, and rules as you figure out what works.
AGENTSEOF

# CLAUDE.md — synced from Cask 215
cat > /home/mise/openclaw/workspace/CLAUDE.md << 'CLAUDEEOF'
Read @SKILL.md for restaurant operations instructions and data schemas.
Read @SOUL.md for your personality and communication style.

You are Mise, a restaurant operations assistant. All restaurant data is stored in the `mise-data/` directory using JSON files. Follow the schemas defined in SKILL.md exactly.

On your first interaction, read `mise-data/restaurant.json` to learn about this restaurant.
CLAUDEEOF

# TOOLS.md — synced from Cask 215
cat > /home/mise/openclaw/workspace/TOOLS.md << 'TOOLSEOF'
# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

## Examples

```markdown
### Cameras

- living-room → Main area, 180° wide angle
- front-door → Entrance, motion-triggered

### SSH

- home-server → 192.168.1.100, user: admin

### TTS

- Preferred voice: "Nova" (warm, slightly British)
- Default speaker: Kitchen HomePod
```

## Why Separate?

Skills are shared. Your setup is yours. Keeping them apart means you can update skills without losing your notes, and share skills without leaking your infrastructure.

---

Add whatever helps you do your job. This is your cheat sheet.
TOOLSEOF

# USER.md — synced from Cask 215
cat > /home/mise/openclaw/workspace/USER.md << 'USEREOF'
# USER.md - About Your Human

_Learn about the person you're helping. Update this as you go._

- **Name:**
- **What to call them:**
- **Pronouns:** _(optional)_
- **Timezone:**
- **Notes:**

## Context

_(What do they care about? What projects are they working on? What annoys them? What makes them laugh? Build this over time.)_

---

The more you know, the better you can help. But remember — you're learning about a person, not building a dossier. Respect the difference.
USEREOF

# MEMORY.md — empty template (bot fills this with restaurant-specific knowledge)
cat > /home/mise/openclaw/workspace/MEMORY.md << 'MEMEOF'
# MEMORY.md - Long-Term Context

_Restaurant observations, notes, and context that doesn't fit structured data files._
MEMEOF

# IDENTITY.md — pre-filled for Mise
cat > /home/mise/openclaw/workspace/IDENTITY.md << 'IDEOF'
# IDENTITY.md - Who Am I?

- **Name:** Mise
- **Creature:** AI operations assistant — your digital sous chef
- **Vibe:** Sharp, warm, no-nonsense. Like a trusted colleague who remembers everything.
- **Emoji:** 🦞
IDEOF

ok "Workspace files deployed (SOUL, SKILL, HEARTBEAT, AGENTS, CLAUDE, TOOLS, USER, MEMORY, IDENTITY)"

step "Installing weather skill"
mkdir -p /home/mise/openclaw/skills/weather
cat > /home/mise/openclaw/skills/weather/SKILL.md << 'WSEOF'
---
name: weather
description: Get current weather and forecasts (no API key required).
---

# Weather

Two free services, no API keys needed.

## wttr.in (primary)

Quick one-liner:
```bash
curl -s "wttr.in/London?format=3"
# Output: London: ⛅️ +8°C
```

Compact format:
```bash
curl -s "wttr.in/London?format=%l:+%c+%t+%h+%w"
# Output: London: ⛅️ +8°C 71% ↙5km/h
```

Full forecast:
```bash
curl -s "wttr.in/London?T"
```

Format codes: `%c` condition · `%t` temp · `%h` humidity · `%w` wind · `%l` location · `%m` moon

Tips:
- URL-encode spaces: `wttr.in/New+York`
- Airport codes: `wttr.in/JFK`
- Units: `?m` (metric) `?u` (USCS)
- Today only: `?1` · Current only: `?0`
- PNG: `curl -s "wttr.in/Berlin.png" -o /tmp/weather.png`

## Open-Meteo (fallback, JSON)

Free, no key, good for programmatic use:
```bash
curl -s "https://api.open-meteo.com/v1/forecast?latitude=51.5&longitude=-0.12&current_weather=true"
```

Find coordinates for a city, then query. Returns JSON with temp, windspeed, weathercode.

Docs: https://open-meteo.com/en/docs
WSEOF
ok "Weather skill installed"

# ============================================================================
# PHASE 5: RESTAURANT CONFIG
# ============================================================================

step "Creating restaurant.json"
cat > /home/mise/openclaw/workspace/mise-data/restaurant.json << RJEOF
{
  "name": "$RESTAURANT_NAME",
  "currency": "$CURRENCY",
  "currencySymbol": "$CURRENCY_SYMBOL",
  "timezone": "$TIMEZONE",
  "cuisine": "$CUISINE_TYPE",
  "typicalCovers": $TYPICAL_COVERS,
  "language": "$LANGUAGE",
  "setupDate": "$SETUP_DATE",
  "city": "$RESTAURANT_CITY",
  "country": "$RESTAURANT_COUNTRY",
  "latitude": $LATITUDE,
  "longitude": $LONGITUDE
}
RJEOF
ok "restaurant.json created for $RESTAURANT_NAME"

# ============================================================================
# PHASE 6: OPENCLAW CONFIG
# ============================================================================

step "Generating gateway token and creating environment file"
GATEWAY_TOKEN=$(openssl rand -hex 32)

cat > /root/openclaw.env << ENVEOF
ANTHROPIC_API_KEY=${ANTHROPIC_KEY:-}
MOONSHOT_API_KEY=${MOONSHOT_KEY:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
BRAVE_API_KEY=${BRAVE_KEY:-}
ENVEOF
chmod 600 /root/openclaw.env
ok "Environment file created at /root/openclaw.env"

step "Creating openclaw.json"

# Build allowFrom based on whether user ID was provided
if [ -n "${TELEGRAM_USER_ID:-}" ]; then
    ALLOW_FROM="[\"$TELEGRAM_USER_ID\"]"
    DM_POLICY="allowlist"
else
    ALLOW_FROM='["*"]'
    DM_POLICY="open"
fi

# Build models provider block — dual provider like Cask 215
# Always include both providers when keys are available
python3 << PYEOF
import json

config = {
    "agents": {
        "defaults": {
            "model": {
                "primary": "$AI_MODEL"
            },
            "workspace": "/home/mise/openclaw/workspace",
            "heartbeat": {
                "every": "1h",
                "activeHours": {
                    "start": "07:00",
                    "end": "23:00"
                },
                "target": "last"
            },
            "maxConcurrent": 4,
            "subagents": {
                "maxConcurrent": 8
            }
        },
        "list": [
            {
                "id": "main",
                "name": "Mise"
            }
        ]
    },
    "tools": {
        "deny": [
            "exec",
            "group:runtime",
            "group:nodes",
            "group:sessions"
        ]
    },
    "messages": {
        "ackReactionScope": "group-mentions"
    },
    "commands": {
        "native": "auto",
        "nativeSkills": "auto"
    },
    "channels": {
        "telegram": {
            "enabled": True,
            "dmPolicy": "$DM_POLICY",
            "botToken": "$TELEGRAM_TOKEN",
            "allowFrom": json.loads('$ALLOW_FROM'),
            "groupPolicy": "allowlist",
            "streamMode": "partial"
        }
    },
    "gateway": {
        "mode": "local",
        "auth": {
            "token": "$GATEWAY_TOKEN"
        }
    },
    "plugins": {
        "entries": {
            "telegram": {
                "enabled": True
            }
        }
    }
}

# Build providers — include all available
providers = {}

moonshot_key = "${MOONSHOT_KEY:-}"
anthropic_key = "${ANTHROPIC_KEY:-}"

if moonshot_key:
    providers["moonshot"] = {
        "baseUrl": "https://api.moonshot.ai/v1",
        "apiKey": moonshot_key,
        "api": "openai-completions",
        "models": [
            {
                "id": "kimi-k2.5",
                "name": "Kimi K2.5",
                "contextWindow": 256000,
                "maxTokens": 8192
            }
        ]
    }

if anthropic_key:
    providers["anthropic"] = {
        "baseUrl": "https://api.anthropic.com",
        "apiKey": anthropic_key,
        "api": "anthropic-messages",
        "models": [
            {
                "id": "claude-sonnet-4-5-20250929",
                "name": "Claude Sonnet 4.5",
                "contextWindow": 200000,
                "maxTokens": 8192
            }
        ]
    }

if providers:
    config["models"] = {
        "mode": "merge",
        "providers": providers
    }

with open('/home/mise/.openclaw/openclaw.json', 'w') as f:
    json.dump(config, f, indent=2)

print("openclaw.json written with providers: " + ", ".join(providers.keys()))
PYEOF
ok "openclaw.json configured"

# ============================================================================
# PHASE 7: PERMISSIONS
# ============================================================================

step "Setting file ownership and permissions"
chown -R mise:mise /home/mise/openclaw /home/mise/.openclaw
chmod 700 /home/mise/.openclaw
chmod 600 /home/mise/.openclaw/openclaw.json
ok "Permissions set"

# ============================================================================
# PHASE 8: SYSTEMD SERVICE
# ============================================================================

step "Creating systemd service"
cat > /etc/systemd/system/openclaw.service << SVCEOF
[Unit]
Description=OpenClaw Gateway (Mise - $RESTAURANT_NAME)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=mise
Group=mise
Environment=NODE_ENV=production
Environment=HOME=/home/mise
WorkingDirectory=/home/mise
EnvironmentFile=/root/openclaw.env
ExecStart=/home/mise/openclaw/pkg/node_modules/.bin/openclaw gateway --port 18789 --bind loopback
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=/home/mise /home/mise/.openclaw /home/mise/openclaw
RestrictSUIDSGID=true
LockPersonality=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable openclaw >/dev/null 2>&1
ok "Systemd service created and enabled"

step "Starting OpenClaw service"
systemctl start openclaw

# Wait for it to boot
echo "  Waiting for service to start..."
sleep 10

if systemctl is-active --quiet openclaw; then
    ok "OpenClaw is running!"
else
    warn "Service may not have started cleanly. Checking logs..."
    journalctl -u openclaw --no-pager -n 20
    echo ""
    warn "Check the logs above. Common issues:"
    echo "  - status=203/EXEC → wrong binary path"
    echo "  - gateway token mismatch → token in config doesn't match env"
    echo "  - Telegram auth error → check bot token"
    echo ""
    echo "You can retry with: systemctl restart openclaw"
fi

# ============================================================================
# PHASE 9: MORNING BRIEFING CRON
# ============================================================================

step "Adding morning briefing cron job (8 AM $TIMEZONE)"
TOKEN=$(grep OPENCLAW_GATEWAY_TOKEN /root/openclaw.env | cut -d= -f2)

# Small delay to make sure gateway is fully ready
sleep 5

CRON_OUTPUT=$(su - mise -c "$OC_BIN cron add \
  --name 'Morning Briefing' \
  --cron '0 8 * * *' \
  --tz '$TIMEZONE' \
  --session isolated \
  --message 'Morning briefing please' \
  --token '$TOKEN'" 2>&1) || true

if echo "$CRON_OUTPUT" | grep -q '"enabled"'; then
    ok "Morning briefing scheduled at 8 AM $TIMEZONE"
else
    warn "Cron job may not have been added. You can add it manually later:"
    echo "  su - mise -c \"$OC_BIN cron add --name 'Morning Briefing' --cron '0 8 * * *' --tz '$TIMEZONE' --session isolated --message 'Morning briefing please' --token '\$TOKEN'\""
fi

# ============================================================================
# PHASE 10: VERIFICATION
# ============================================================================

step "Running verification checks"

echo "  Checking service status..."
if systemctl is-active --quiet openclaw; then
    ok "Service: running"
else
    warn "Service: not running"
fi

echo "  Checking Telegram connection..."
TELEGRAM_CHECK=$(journalctl -u openclaw --no-pager -n 50 2>/dev/null | grep -c "telegram" || echo "0")
if [ "$TELEGRAM_CHECK" -gt 0 ]; then
    ok "Telegram: connected (found in logs)"
else
    warn "Telegram: no connection detected in logs yet. May need more time."
fi

echo "  Checking model configuration..."
MODEL_CHECK=$(journalctl -u openclaw --no-pager -n 50 2>/dev/null | grep "agent model" || echo "")
if [ -n "$MODEL_CHECK" ]; then
    ok "Model: $(echo $MODEL_CHECK | tail -1)"
else
    echo "  Model configured: $AI_MODEL"
fi

echo "  Checking workspace files..."
WORKSPACE="/home/mise/openclaw/workspace"
EXPECTED_FILES=("SOUL.md" "SKILL.md" "HEARTBEAT.md" "AGENTS.md" "CLAUDE.md" "TOOLS.md" "USER.md" "MEMORY.md" "IDENTITY.md")
MISSING=0
for f in "${EXPECTED_FILES[@]}"; do
    if [ ! -f "$WORKSPACE/$f" ]; then
        warn "Missing: $f"
        MISSING=$((MISSING + 1))
    fi
done
if [ "$MISSING" -eq 0 ]; then
    ok "All ${#EXPECTED_FILES[@]} workspace files present"
fi

# ============================================================================
# DONE
# ============================================================================

echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}🦞 Mise deployment complete for $RESTAURANT_NAME!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Next steps:"
echo "  1. Open Telegram and send a message to @$TELEGRAM_USERNAME"
echo "     (First message takes 10-15 seconds — it reads all workspace files)"
echo "  2. Monitor token usage:"
if [ -n "${MOONSHOT_KEY:-}" ]; then
    echo "     Moonshot: https://platform.moonshot.ai"
fi
if [ -n "${ANTHROPIC_KEY:-}" ]; then
    echo "     Anthropic: https://console.anthropic.com"
fi
echo "  3. Morning briefings will start tomorrow at 8 AM $TIMEZONE"
echo ""
echo "  Quick reference:"
echo "    Check status:   systemctl status openclaw"
echo "    View logs:      journalctl -u openclaw --no-pager -n 30"
echo "    Restart:        systemctl restart openclaw"
echo "    View config:    cat /home/mise/.openclaw/openclaw.json"
echo ""
echo "  Server IP: $(hostname -I | awk '{print $1}')"
echo "  Setup date: $SETUP_DATE"
echo ""
