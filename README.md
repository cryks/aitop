# aitop

Terminal dashboard for AI coding assistant usage. Runs providers in parallel and renders a unified view with color-coded bars, pacing indicators, and reset countdowns.

![aitop](docs/aitop.png)

---

## Requirements

- Bash 4+
- `jq`
- `curl`
- `sqlite3` (Claude caching and Codex pool accounts)
- `python3` (Gemini token refresh and OpenCode parsing)
- macOS (`security` command for Claude Keychain access)

---

## Quick Start

Run all providers:

```bash
aitop
```

Run a single provider:

```bash
aitop-claude
aitop-codex
aitop-gemini
aitop-opencode
```

---

## Supported Providers

| Provider | Script | Auth Source |
|----------|--------|-------------|
| Claude Code | `aitop-claude` | macOS Keychain (Claude Code OAuth) |
| Codex | `aitop-codex` | `~/.local/share/opencode/auth.json` |
| Gemini CLI | `aitop-gemini` | `~/.gemini/oauth_creds.json` |
| OpenCode | `aitop-opencode` | Cookie file or `AITOP_OPENCODE_COOKIE` env |

---

## Configure Providers

### Claude Code

Requires an active Claude Code login on macOS. Credentials are read from the macOS Keychain.

Environment variables:

| Variable | Description |
|----------|-------------|
| `CLAUDE_USAGE_CACHE_TTL` | Cache TTL in seconds (default: 300) |
| `CLAUDE_USAGE_CACHE` | Set to `0` to disable caching |

Options:

```bash
aitop-claude --no-cache    # Bypass response cache
```

### Codex

Requires an active OpenCode login. Reads auth from `~/.local/share/opencode/auth.json`.

Supports pool accounts via `~/.local/share/opencode/codex-pool.db`.

### Gemini CLI

Requires an active Gemini CLI OAuth login. Reads credentials from `~/.gemini/oauth_creds.json`.

### OpenCode

Requires a browser auth cookie from opencode.ai.

Set the cookie via one of:

1. File: `~/.config/aitop-opencode/cookie`
2. Environment: `AITOP_OPENCODE_COOKIE`

To get the cookie value, open opencode.ai in your browser, open DevTools > Application > Cookies, and copy the value of the `auth` or `__Host-auth` cookie.

Environment variables:

| Variable | Description |
|----------|-------------|
| `AITOP_OPENCODE_COOKIE` | Auth cookie value |
| `AITOP_OPENCODE_WORKSPACE_ID` | Skip workspace discovery (format: `wrk_...`) |

---

## Disable Providers

Set environment variables to `0`, `false`, `no`, or `off` to disable specific providers when running `aitop`:

```bash
export AITOP_CLAUDE=0      # Disable Claude
export AITOP_CODEX=0       # Disable Codex
export AITOP_GEMINI=0      # Disable Gemini
export AITOP_OPENCODE=0    # Disable OpenCode
```

---

## Output Format

Each provider renders a section with:

- **Usage bar** — gradient from teal to yellow to red as usage increases
- **Pace indicator** — `✓` on track, `⚠ ahead` of pace, `■ full` at capacity
- **Time bar** — elapsed portion of the current usage window
- **Reset countdown** — time remaining until the window resets

OpenCode additionally shows per-model cost breakdowns (today / this month) and Zen credit balance.

