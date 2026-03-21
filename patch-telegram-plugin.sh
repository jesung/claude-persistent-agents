#!/usr/bin/env bash
# patch-telegram-plugin.sh — applies two patches to the cached Claude Telegram
# plugin to support per-agent state directories (TELEGRAM_STATE_DIR).
#
# Run once after installing Claude Code, and re-run after any plugin update
# that overwrites the cache.
#
# Patches:
#   1. server.ts  — read STATE_DIR from TELEGRAM_STATE_DIR env var (with fallback)
#   2. package.json — remove "bun install" from the start script (install is done
#                     at cache population time; re-running it on every start
#                     causes unnecessary delays and duplicate plugin instances)

set -euo pipefail

CACHE_DIR="${HOME}/.claude/plugins/cache/claude-plugins-official/telegram/0.0.1"
SERVER="${CACHE_DIR}/server.ts"
PKG="${CACHE_DIR}/package.json"

if [[ ! -f "$SERVER" ]]; then
  echo "Plugin cache not found at: $CACHE_DIR"
  echo ""
  echo "Populate it first by running Claude Code with the Telegram channel:"
  echo "  claude --channels plugin:telegram@claude-plugins-official"
  echo "Then re-run this script."
  exit 1
fi

# --- Patch 1: server.ts ---
OLD_LINE="const STATE_DIR = join(homedir(), '.claude', 'channels', 'telegram')"
NEW_LINE="const STATE_DIR = process.env.TELEGRAM_STATE_DIR ?? join(homedir(), '.claude', 'channels', 'telegram')"

if grep -qF "TELEGRAM_STATE_DIR" "$SERVER"; then
  echo "server.ts:  already patched — skipping"
else
  # Use a temp file for safety.
  TMP=$(mktemp)
  sed "s|${OLD_LINE}|${NEW_LINE}|" "$SERVER" > "$TMP"
  if grep -qF "TELEGRAM_STATE_DIR" "$TMP"; then
    mv "$TMP" "$SERVER"
    echo "server.ts:  patched ✓"
  else
    rm "$TMP"
    echo "server.ts:  ERROR — expected line not found. Check the plugin version."
    echo "  Expected: $OLD_LINE"
    exit 1
  fi
fi

# --- Patch 2: package.json ---
if grep -q '"start": "bun server.ts"' "$PKG"; then
  echo "package.json: already patched — skipping"
else
  TMP=$(mktemp)
  sed 's|"start": "bun install --no-summary && bun server.ts"|"start": "bun server.ts"|' "$PKG" > "$TMP"
  if grep -q '"start": "bun server.ts"' "$TMP"; then
    mv "$TMP" "$PKG"
    echo "package.json: patched ✓"
  else
    rm "$TMP"
    echo "package.json: WARNING — start script not in expected format. Current value:"
    grep '"start"' "$PKG" || echo "  (start key not found)"
    echo "  Skipping this patch — check manually."
  fi
fi

echo ""
echo "Done. Plugin is ready for multi-agent use."
