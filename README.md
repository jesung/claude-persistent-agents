# claude-persistent-agents

Infrastructure for running Claude Code agents persistently via Telegram — surviving reboots, terminal closes, and supporting full multi-turn conversations.

> **Built on Claude Code's native `--channels` feature.** This repo is not a custom Telegram integration — it's a thin layer of systemd + tmux infrastructure on top of the [official Claude Code Telegram channel plugin](https://docs.anthropic.com/en/docs/claude-code/channels). The plugin handles all the bot logic; this repo just keeps it alive.

## Background: Claude Code Channels

Claude Code has a first-class `--channels` feature that connects Claude to external messaging platforms via MCP plugin servers. The official Telegram plugin lets you message Claude directly from Telegram:

```bash
claude --channels plugin:telegram@claude-plugins-official
```

This works great interactively. The problem comes when you want it to run **persistently** — in the background, surviving terminal closes, across reboots — especially with **multiple agents each on their own bot**.

## The Problems This Repo Solves

**1. Headless PTY bug**
In a headless environment (systemd, `nohup`, or a custom PTY wrapper), Claude drops the MCP channel connection after processing one message. The bot responds once, then goes silent. Root cause: Claude's MCP plugin requires a full virtual terminal to stay alive between turns.

**2. Session persistence**
An agent started in a terminal tab dies when that tab is closed.

**3. Multiple agents, one plugin cache**
The official plugin's state directory is hardcoded to `~/.claude/channels/telegram/`. Running two agents means both use the same bot token and compete for the same Telegram updates — only one gets each message.

## The Solution

**tmux** provides a real virtual terminal (PTY) without a physical display. Running Claude inside a tmux session keeps the MCP plugin alive for multi-turn conversations. A service manager (**systemd** on Linux, **launchd** on macOS) handles lifecycle — starting on boot and restarting on failure.

For multi-agent use, a one-line patch to the cached plugin adds `TELEGRAM_STATE_DIR` env var support, letting each agent point to its own state directory and bot token.

```
systemd / launchd
  └── claude-tmux-launch <agent>           # launcher: keeps service manager tracking liveness
        └── tmux -L <agent> new-session -d -s claude-<agent>   # per-agent tmux server
              └── claude --channels plugin:telegram@claude-plugins-official
                    └── bun server.ts      # official Claude Code Telegram plugin
```

## What's in this repo

| File | Purpose |
|------|---------|
| `claude-tmux-launch` | Launcher: starts claude in a named tmux session, loops until it exits |
| `claude-agent@.service` | systemd user service template (Linux) — one instance per agent |
| `com.claude.agent.plist` | launchd plist template (macOS, **untested**) — one copy per agent |
| `patch-telegram-plugin.sh` | One-line patch for multi-agent `TELEGRAM_STATE_DIR` support |
| `setup-agent.sh` | Interactive helper to configure a new agent's bot token and access policy |

## Prerequisites

- [Claude Code](https://claude.ai/code) installed (`claude` in PATH)
- [Bun](https://bun.sh) installed (the Telegram plugin runs on Bun)
- tmux **3.0+**: `sudo apt-get install -y tmux` (or `brew install tmux`). Check with `tmux -V`. The launcher uses `tmux new-session -e` for env vars, which requires 3.0+.
- **Linux:** systemd (for persistent services) — tested on Ubuntu 22.04
- **macOS:** launchd (untested — see [macOS setup](#macos-launchd-untested) below)
- **Windows:** use WSL2 with systemd enabled, then follow the Linux instructions

## Quick Start (Linux / systemd)

### 1. Populate the plugin cache

Claude Code downloads the Telegram plugin on first use. Run it once to populate the cache, then exit:

```bash
claude --channels plugin:telegram@claude-plugins-official
# Wait for it to start, then Ctrl-C
```

### 2. Patch for multi-agent support _(skip if running a single agent)_

The plugin's state directory is hardcoded by default. This patch adds `TELEGRAM_STATE_DIR` env var support so each agent can have its own bot token:

```bash
./patch-telegram-plugin.sh
```

### 3. Set up an agent

```bash
./setup-agent.sh my-agent
```

Creates `~/.claude/channels/telegram-my-agent/` with your bot token and access policy. You'll need a bot token from [@BotFather](https://t.me/BotFather).

### 4. Install the launcher

```bash
mkdir -p ~/bin
cp claude-tmux-launch ~/bin/
chmod +x ~/bin/claude-tmux-launch
```

### 5. Install and configure the systemd unit

```bash
mkdir -p ~/.config/systemd/user
cp claude-agent@.service ~/.config/systemd/user/
```

Edit the unit to match your setup:

```bash
nano ~/.config/systemd/user/claude-agent@.service
```

- `WorkingDirectory` — directory containing your agent subdirs (e.g. `~/agents/%i` where `~/agents/my-agent/CLAUDE.md` is your agent's system prompt)
- `Environment=PATH` — ensure bun and claude are on the path
- `ExecStartPost` / `ExecStopPost` — the template includes notification hooks (`telegram-notify`). Remove these lines or replace them with your own notification script if you don't have one.

### 6. Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable --now claude-agent@my-agent
```

### 7. Accept the first-launch trust prompt

On first launch of a new agent directory, Claude Code shows a folder trust prompt. Attach to the tmux session and press Enter to accept:

```bash
tmux -L my-agent attach -t claude-my-agent
# Press Enter to select "Yes, I trust this folder"
# Then Ctrl-b d to detach
```

This only happens once per agent directory.

### 8. Verify

```bash
# Service is running
systemctl --user status claude-agent@my-agent

# tmux session exists (each agent has its own tmux server, pass -L)
tmux -L my-agent list-sessions            # should show: claude-my-agent

# Telegram plugin is polling
ps aux | grep 'bun server.ts'             # should show one process per agent

# Watch the agent live (Ctrl-b d to detach)
tmux -L my-agent attach -t claude-my-agent
```

Send your bot a message on Telegram — it should respond, and keep responding across multiple turns.

## Running Multiple Agents

Each agent needs its own bot (from [@BotFather](https://t.me/BotFather)), its own state dir, and its own working directory with a `CLAUDE.md`.

```bash
./setup-agent.sh agent-one
./setup-agent.sh agent-two

systemctl --user enable --now claude-agent@agent-one
systemctl --user enable --now claude-agent@agent-two
```

## Managing Agents

```bash
# Restart (e.g. after updating CLAUDE.md)
systemctl --user restart claude-agent@my-agent

# Restart all at once
systemctl --user restart 'claude-agent@*'

# Follow logs
journalctl --user -u claude-agent@my-agent -f

# Status of all agents
systemctl --user status 'claude-agent@*'

# Send a command to a running agent (without attaching)
tmux -L my-agent send-keys -t claude-my-agent '/some-command' Enter

# Read an agent's recent output (without attaching)
tmux -L my-agent capture-pane -t claude-my-agent -p | tail -20
```

## macOS (launchd) — UNTESTED

> **This has not been tested on a real macOS machine.** The tmux launcher and plugin patch are portable, but the launchd integration is a best-effort port from the tested Linux/systemd setup. If you try this and hit issues, please open an issue.

Steps 1–4 from the Linux quick start are identical (populate cache, patch, setup agent, install launcher). The difference is how the service is managed.

### 5. Install the launchd plist

```bash
# Copy and customize the template for your agent
cp com.claude.agent.plist ~/Library/LaunchAgents/com.claude.agent.my-agent.plist
```

Edit the plist — replace every `AGENT_NAME` with your agent name and `USERNAME` with your macOS username:

```bash
sed -i '' "s/AGENT_NAME/my-agent/g; s/USERNAME/$(whoami)/g" \
  ~/Library/LaunchAgents/com.claude.agent.my-agent.plist
```

Also update `WorkingDirectory` to point to the directory containing your agent's `CLAUDE.md`.

### 6. Load and start

```bash
launchctl load ~/Library/LaunchAgents/com.claude.agent.my-agent.plist
```

### 7. Accept the trust prompt and verify

```bash
# Attach to accept the first-launch trust prompt
tmux -L my-agent attach -t claude-my-agent
# Press Enter on "Yes, I trust this folder", then Ctrl-b d to detach

# Check it's running
tmux -L my-agent list-sessions
ps aux | grep 'bun server.ts'

# View logs
tail -f /tmp/claude-agent-my-agent.log
```

### Managing agents (macOS)

```bash
# Stop
launchctl unload ~/Library/LaunchAgents/com.claude.agent.my-agent.plist

# Start
launchctl load ~/Library/LaunchAgents/com.claude.agent.my-agent.plist

# Restart (unload + load)
launchctl unload ~/Library/LaunchAgents/com.claude.agent.my-agent.plist
launchctl load ~/Library/LaunchAgents/com.claude.agent.my-agent.plist

# View logs
tail -f /tmp/claude-agent-my-agent.log
```

## Troubleshooting

**Bot responds once then goes silent**
The MCP plugin process died. Check `ps aux | grep 'bun server.ts'` — there should be one per agent. Fix: `systemctl --user restart claude-agent@<name>`. Verify tmux is in use: `tmux -L <name> list-sessions` should show `claude-<name>`.

**Bot goes silent after being fine for a while**
The bun health check may not have triggered yet, or the 5-minute timeout is too long for your use case. Check with `ps aux | grep 'bun server.ts'` — if bun is gone, restart manually: `systemctl --user restart claude-agent@<name>`. The health check (see [How the launcher works](#how-the-launcher-works)) will handle this automatically after the timeout.

**No response at all**
- Check `access.json`: `dmPolicy` and `allowFrom` must allow your Telegram user ID
- Verify the bot token in `.env` is correct
- Check the service started: `systemctl --user status claude-agent@<name>`

**Multiple agents conflict (both stop responding)**
Each agent must have a unique bot token — two pollers on the same token split updates. Check `.env` files are all different.

**After a plugin update, multi-agent stops working**
`patch-telegram-plugin.sh` patches the plugin cache. Plugin updates can overwrite it. Re-run: `./patch-telegram-plugin.sh`.

**Don't mix systemd and manual `--channels` sessions**
If systemd is managing Telegram for an agent, don't also start that agent manually with `--channels`. Two pollers on the same token will compete.

## How the launcher works

`claude-tmux-launch` does more than just start Claude — it also monitors it:

1. **Per-agent tmux server** — uses `-L <agent>` to give each agent its own tmux server socket. Combined with `KillMode=control-group` in the systemd unit, this ensures all child processes (claude, bun, any spawned tools) are cleanly reaped when the service stops. No orphaned bun instances accumulating across restarts.

2. **Bun health check** — the launcher polls every 10 seconds for a running `bun` descendant. If bun dies while Claude stays alive (leaving the bot silently unresponsive), the health check detects it and kills the tmux session after a 5-minute timeout, triggering a clean systemd restart. A 2-minute grace period after launch prevents false restarts on startup.

3. **Tool-aware restart prevention** — if Claude is actively running tools (builds, shell commands, etc.) the bun-missing timer resets, preventing spurious restarts during long-running tasks.

## Caveats

- **`TELEGRAM_STATE_DIR` patch** — targets a specific line in the cached plugin. May need updating if the official plugin is significantly reworked. The patch script will tell you if it can't find the expected line.
- **`--dangerously-skip-permissions`** — used in the launcher for non-interactive operation. Remove it if you want to approve tool calls manually (you can respond via `tmux -L <agent> attach`).
- **tmux `-L` flag** — all tmux commands for a managed agent require `-L <agent-name>` to target its server. Plain `tmux list-sessions` will show nothing, since each agent runs on its own isolated socket.
- **Single-agent use** — if you only have one agent, skip step 2 entirely. The patch is only needed for multiple agents with separate tokens.
- **`/telegram:access pair` doesn't work with custom state dirs** — the built-in pairing skill only checks the default `~/.claude/channels/telegram/` path, not `TELEGRAM_STATE_DIR`. For multi-agent setups, use the `allowlist` option in `setup-agent.sh` instead (pre-configures your user ID in `access.json`).

## License

MIT
