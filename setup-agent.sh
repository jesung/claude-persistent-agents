#!/usr/bin/env bash
# setup-agent.sh — interactive helper to configure a new Claude agent for
# persistent Telegram access via systemd + tmux.
#
# Usage: ./setup-agent.sh <agent-name>
#
# Creates:
#   ~/.claude/channels/telegram-<name>/.env
#   ~/.claude/channels/telegram-<name>/access.json
#   ~/.claude/channels/telegram-<name>/approved/

set -euo pipefail

AGENT="${1:?Usage: ./setup-agent.sh <agent-name>}"
STATE_DIR="${HOME}/.claude/channels/telegram-${AGENT}"

echo "Setting up Telegram state for agent: ${AGENT}"
echo "State dir: ${STATE_DIR}"
echo ""

# --- Bot token ---
echo "Step 1: Get a bot token from @BotFather on Telegram."
echo "  Send /newbot, follow the prompts, copy the token."
echo ""
read -rp "Bot token: " TOKEN
if [[ -z "$TOKEN" ]]; then
  echo "Error: token cannot be empty."
  exit 1
fi

# --- State dir ---
mkdir -p "${STATE_DIR}/approved"
chmod 700 "${STATE_DIR}"

printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "${STATE_DIR}/.env"
chmod 600 "${STATE_DIR}/.env"
echo "  .env written."

# --- Access policy ---
echo ""
echo "Step 2: Access policy."
echo "  allowlist — only your Telegram user ID can message the bot (recommended)"
echo "  pairing   — anyone can initiate pairing; you approve via /telegram:access"
echo ""
read -rp "Policy [allowlist/pairing, default: pairing]: " POLICY
POLICY="${POLICY:-pairing}"

if [[ "$POLICY" == "allowlist" ]]; then
  echo ""
  echo "  To find your Telegram user ID, message @userinfobot on Telegram."
  read -rp "  Your Telegram user ID: " UID_VAL
  if [[ -z "$UID_VAL" ]]; then
    echo "Error: user ID required for allowlist policy."
    exit 1
  fi
  cat > "${STATE_DIR}/access.json" <<EOF
{
  "dmPolicy": "allowlist",
  "allowFrom": ["${UID_VAL}"],
  "groups": {},
  "pending": {}
}
EOF
  POLICY="allowlist"
else
  cat > "${STATE_DIR}/access.json" <<EOF
{
  "dmPolicy": "pairing",
  "allowFrom": [],
  "groups": {},
  "pending": {}
}
EOF
  POLICY="pairing"
fi
chmod 600 "${STATE_DIR}/access.json"
echo "  access.json written (dmPolicy: ${POLICY})."

# --- Summary ---
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Agent '${AGENT}' is configured."
echo ""
echo "Next steps:"
echo ""
echo "  1. Patch the plugin (if not done already):"
echo "       ./patch-telegram-plugin.sh"
echo ""
echo "  2. Install the launcher and unit:"
echo "       cp claude-tmux-launch ~/bin/ && chmod +x ~/bin/claude-tmux-launch"
echo "       cp claude-agent@.service ~/.config/systemd/user/"
echo "       # Edit WorkingDirectory in the unit to point to your agent dir"
echo ""
echo "  3. Enable and start:"
echo "       systemctl --user daemon-reload"
echo "       systemctl --user enable --now claude-agent@${AGENT}"
echo ""
echo "  4. Accept the first-launch trust prompt (once only):"
echo "       tmux attach -t claude-${AGENT}"
echo "       # Press Enter on 'Yes, I trust this folder', then Ctrl-b d to detach"
echo ""
echo "  5. Verify it's running:"
echo "       systemctl --user status claude-agent@${AGENT}"
echo "       ps aux | grep 'bun server.ts'   # one process per active agent"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
