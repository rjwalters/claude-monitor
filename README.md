# Claude Monitor

Monitor your Claude AI usage with a macOS menu-bar widget. Polls the Anthropic
API with long-lived OAuth tokens (one or many) and surfaces quota, reset times,
and usage trends without leaving your menu bar.

![Menu bar popover with the summary table](window.png)
![Per-account usage history chart](plot_window.png)

## Why?

Anthropic doesn't expose a documented public API for checking consumer
subscription usage (Pro/Max). The web dashboard at
https://claude.ai/settings/usage shows your limits but has no programmatic
equivalent.

Claude Monitor calls the same internal endpoints that Claude Code uses, using
OAuth tokens you provide, and renders the data locally on your Mac.

## Features

- **Live usage % in the menu bar** (Stats-app style), color-coded — orange at
  90%, red above 95%.
- **Summary table popover.** All accounts at a glance: session %, weekly %,
  reset times, data freshness, token health, and a one-click chart launcher
  per row.
- **Headroom score** (0–100). A single number — `100 − max(session %,
  weekly %)` — answering "which account should I be using". Default sort.
- **Click any column header to sort.** Account, Headroom, percents, reset
  times, freshness, token status. Chevron marks the active column; click
  again to flip direction. Rows without data sort to the bottom.
- **Pin which account drives the menu bar.** Radio button on each row. Click
  to pin; click again to revert to auto-pick (most-available). Pinning
  survives restarts.
- **Per-row history charts.** Click the chart icon to open a usage-history
  window for that account; the popover stays open so you can open several
  side-by-side and compare.
- **Multi-account.** Add accounts one-by-one via a token from
  `claude setup-token`, or bulk-import from a `.env` file with
  `ACCOUNT_EMAIL_N` / `ACCOUNT_KEY_N` pairs.
- **Roll Token wizard.** Guided revoke-all + re-mint for an account's
  long-lived token (right-click its row → "Roll Token…"). A temporary stopgap
  until Anthropic ships a token-management API — see
  [Rolling a Token](#rolling-a-token-revoke--re-mint).
- **All data stored locally** in SQLite at `~/.claude-monitor/usage.db`.

## Quick Install

### 1. Prerequisites

- macOS 13+ (Ventura or later)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed (you
  use it to generate the OAuth tokens via `claude setup-token`)

### 2. Download

Grab `ClaudeMonitor.zip` from
[Releases](https://github.com/rjwalters/claude-monitor/releases), unzip, and
move `ClaudeMonitor.app` to `/Applications`.

**First run:** right-click → **Open** (required for unsigned apps).

### 3. Get a Long-Lived OAuth Token

Run this in a terminal:

```bash
claude setup-token
```

It opens a browser, asks you to authorize, and prints a token like
`sk-ant-oat01-…`. These tokens are **long-lived (~1 year)** so a single
authorization powers the menu bar for the entire lifetime — no refresh dance
needed. If you ever need to revoke and replace one (e.g., after a leak), see
[Rolling a Token](#rolling-a-token-revoke--re-mint).

### 4. Add the Account

1. Click the menu-bar widget.
2. Click **+ Add Account** in the footer.
3. Paste the token, click **Add Account**.

Your usage data shows up in the menu bar immediately.

### Multiple Accounts

If you maintain tokens for several accounts (e.g., in a `.env` for an agent
pool), use the **Bulk Import** field in the Add Account dialog:

```env
ACCOUNT_EMAIL_1=you@example.com
ACCOUNT_KEY_1=sk-ant-oat01-...
ACCOUNT_EMAIL_2=agent@example.com
ACCOUNT_KEY_2=sk-ant-oat01-...
```

Point the importer at the file path; each pair is validated via a ping and
added on success. Pinning, sorting, and per-account charts work the same way
regardless of how the accounts were added.

#### Master account list (auto-loaded at launch)

Instead of importing by hand, keep a master list that the app loads every time
it starts:

- `~/.claude-monitor/accounts.env` — the master list (shared source of truth)
- `~/.claude-monitor/accounts.local.env` — local overrides and additions (keep
  this machine-specific; don't share it)

Both use the same `ACCOUNT_EMAIL_N` / `ACCOUNT_KEY_N` format. At launch the app
merges them (the local file **overrides** the master token for a matching email
and **appends** any new emails), then imports the result. Loading is
**additive**: accounts in the lists are added or have their token refreshed, but
accounts already in the app that aren't listed are left untouched — nothing is
removed. Store these files with `chmod 600`; they contain live tokens.

### Rolling a Token (revoke + re-mint)

> **Temporary workaround.** Anthropic exposes no supported API to list, revoke,
> or programmatically mint long-lived `sk-ant-oat01` tokens, so this workflow
> leans on undocumented claude.ai internals plus manual browser steps. It
> should be revisited (and ideally replaced) once Anthropic ships a real
> token-management API — see
> [anthropics/claude-code#43801](https://github.com/anthropics/claude-code/issues/43801)
> (revocation doesn't reliably invalidate tokens),
> [#22995](https://github.com/anthropics/claude-code/issues/22995)
> (token/session management dashboard request),
> [#48373](https://github.com/anthropics/claude-code/issues/48373)
> (`claude setup-token --list` / `--revoke` request), and
> [#59378](https://github.com/anthropics/claude-code/issues/59378)
> (per-session token minting).

If a token leaks — or you just want to rotate one — right-click the account's
row in the popover and choose **"Roll Token…"**. A per-account wizard window
opens (its header shows a "Last rolled …" timestamp) and walks you through
four steps:

1. **Log in as this account.** A button opens
   `https://claude.ai/settings/claude-code` in your browser; make sure the
   browser is signed in as the account being rolled.
2. **Revoke the old tokens.** A button copies a browser-console script with
   the account's org id baked in. Paste it into the browser console (⌥⌘J) on
   the logged-in claude.ai page and press Return. It revokes **every**
   authorization token on the account — this signs out all devices using it.
3. **Mint a new token.** Run `claude setup-token` in a terminal (copy button
   provided), complete the browser login, and paste the printed
   `sk-ant-oat01-…` back into the wizard. The wizard verifies the token and
   **rejects it if its org id doesn't match the account being rolled** — a
   guard against accidentally pasting a different account's token into the
   wrong roll.
4. **Verify the old token is revoked.** After a successful import, the wizard
   pings the token this account had *before* the roll. If the API rejects it
   with 401 you get "Revoked ✓"; if it still answers (200 or 429 — both mean
   the token still authenticates) you get "Still valid!"; a network or server
   error shows "Couldn't check".

#### Why it works this way (undocumented endpoints)

The console script hits internal claude.ai endpoints with no public,
documented equivalent:

- List tokens:
  `GET https://claude.ai/api/oauth/organizations/{org}/oauth_tokens`
- Revoke one:
  `POST https://claude.ai/api/oauth/organizations/{org}/oauth_tokens/{id}/revoke`

Both authenticate with the **claude.ai web session cookie**
(`credentials: 'include'`), not the Bearer token — the OAuth token itself gets
`account_session_invalid`. That's why revocation can only run pasted into a
browser console on a logged-in claude.ai page, never from the app itself.
Minting can't be automated either: `claude setup-token` requires interactive
browser OAuth.

The script is defensive about known flakiness: it re-lists live tokens between
revoke rounds and retries stragglers for up to 10 rounds, and a 403 on the
list call means the browser is logged into a different account (the script
aborts with a clear error).

Because these endpoints are undocumented, they may change without notice. If a
roll stops working, the script template in `TokenRoller.revokeAllScript`
(`menubar-app/ClaudeMonitor/Sources/TokenRoller.swift`) is the single place to
update.

Finally, server-side revocation is known to lag or silently fail (see
anthropics/claude-code#43801 above) — which is exactly why step 4 exists: the
app independently verifies the old token with its own ping rather than
trusting that the revoke succeeded.

## Direct API Access (no app needed)

The whole app is just a wrapper around a single, cheap API call. With a
`sk-ant-oat01-…` token from `claude setup-token` you can fetch the same usage
data the menu bar shows, using only `curl`. Both a 200 (Haiku reply) and a 429
(rate-limited) response carry the usage data in headers:

```bash
TOKEN='sk-ant-oat01-...'   # from `claude setup-token`

curl -sS -D - -o /dev/null https://api.anthropic.com/v1/messages \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-version: 2023-06-01" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "User-Agent: claude-code/2.0.37" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"x"}]}' \
  | grep -i '^anthropic-'
```

The interesting headers in the response:

| Header                                        | Meaning                              |
| --------------------------------------------- | ------------------------------------ |
| `anthropic-organization-id`                   | Which account this token belongs to  |
| `anthropic-ratelimit-unified-5h-utilization`  | Session quota used (0.0–1.0)         |
| `anthropic-ratelimit-unified-5h-reset`        | Session reset (epoch seconds)        |
| `anthropic-ratelimit-unified-7d-utilization`  | Weekly quota used (0.0–1.0)          |
| `anthropic-ratelimit-unified-7d-reset`        | Weekly reset (epoch seconds)         |
| `anthropic-ratelimit-unified-status`          | `allowed` / `allowed_warning` / etc. |

Each call costs ~1 Haiku output token (effectively free). The
`oauth-2025-04-20` beta flag is what lets the OAuth-issued token authenticate
against `/v1/messages`.

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────┐
│  OAuth tokens                                                            │
│    - `claude setup-token` (single, paste-in)                             │
│    - `.env` bulk import (ACCOUNT_EMAIL_N / ACCOUNT_KEY_N)                │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ stored in
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  SQLite — ~/.claude-monitor/usage.db                                     │
│    accounts │ oauth_credentials │ usage_history │ settings               │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ read by
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  OAuthPoller → Anthropic API                                             │
│    - Each account pinged once per 10 min (staggered)                     │
│    - Tokens are long-lived (1 yr); no refresh dance needed               │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ data drives
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  Menu-bar app (SwiftUI)                                                  │
│    Left-click  → summary-table popover                                   │
│    Right-click → quick account switcher (opens chart for the pick)       │
└──────────────────────────────────────────────────────────────────────────┘
```

## Development

### Requirements

- macOS 13+
- Xcode Command Line Tools (`xcode-select --install`)
- Claude Code (to generate tokens)

### Build & Run

```bash
git clone https://github.com/rjwalters/claude-monitor.git
cd claude-monitor/menubar-app/ClaudeMonitor
swift build
.build/debug/ClaudeMonitor &
```

### Build for Distribution

```bash
./scripts/build-macos-app.sh
```

The script auto-detects the installed `claude-code` npm version and patches
the User-Agent string in `AnthropicAPI.swift` before compiling. Output:
`build/ClaudeMonitor.app` and `build/ClaudeMonitor.zip`.

When replacing `/Applications/ClaudeMonitor.app`, you must `rm -rf` the old
bundle before copying — `cp -R` over a running app does not replace the
binary. See `CLAUDE.md` for the exact sequence.

## Headless Mode / Linux

The same package builds on Linux as a headless daemon — no UI, same poll loop
(account-file sync, 10-minute usage pings, 20-minute Fable probes) writing the
same `~/.claude-monitor/usage.db` and `ranking.json`. This is what Loom hosts
run.

### Build (Linux)

Requires a Swift toolchain ([swift.org](https://www.swift.org/install/) or the
`swift:6.1` Docker image) and the SQLite dev headers:

```bash
sudo apt-get install libsqlite3-dev   # (yum: sqlite-devel)
cd claude-monitor/menubar-app/ClaudeMonitor
swift build -c release
sudo cp .build/release/ClaudeMonitor /usr/local/bin/claude-monitor
```

### Run

Put your accounts in `~/.claude-monitor/accounts.env`
(`ACCOUNT_EMAIL_N` / `ACCOUNT_KEY_N` pairs, same format as the app's bulk
import — see [Multiple Accounts](#multiple-accounts)), then:

```bash
claude-monitor                  # poll loop, logs to stdout + ~/.claude-monitor/debug.log
claude-monitor --once           # one poll cycle, write ranking.json, exit
claude-monitor --interval 300   # override per-account poll interval (seconds, min 60)
```

Edits to `accounts.env` / `accounts.local.env` are picked up automatically
while the daemon runs. A sample systemd user unit is provided at
`scripts/claude-monitor.service`.

On macOS the same headless loop is available as `ClaudeMonitor --headless`
(the bare binary or the app bundle's `Contents/MacOS/ClaudeMonitor`).

## Auto-Start on Login (Optional)

```bash
mkdir -p ~/Library/LaunchAgents

cat > ~/Library/LaunchAgents/com.claude-monitor.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.claude-monitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/ClaudeMonitor.app/Contents/MacOS/ClaudeMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.claude-monitor.plist
```

To remove auto-start:

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-monitor.plist
rm ~/Library/LaunchAgents/com.claude-monitor.plist
```

## Troubleshooting

### Menu bar shows "LLM --"

No data yet. Click the widget → **+ Add Account** → paste a token from
`claude setup-token`.

### A new account doesn't appear after import

The import dialog calls `refreshAll` after a successful add, so all 10/13/etc.
accounts should appear when the popover reopens. If a token dot stays gray,
the next 30 s poll tick hasn't filled in token status yet — click the
↻ refresh icon in the popover header.

### Rolled token still shows as valid

Anthropic-side revocation is known to be unreliable or slow to take effect
([anthropics/claude-code#43801](https://github.com/anthropics/claude-code/issues/43801)),
which is why the [Roll Token wizard](#rolling-a-token-revoke--re-mint)'s final
step pings the old token itself — still answers (200/429) means still valid,
rejected (401) means revoked — instead of trusting the revoke call. If the
badge says "Still valid!", re-run the revoke console script from step 2 (it
automatically retries tokens that survive a round) and click **Verify old
token revoked** again. "Couldn't check" means the ping itself failed
(network/5xx) — try again later.

### Logs

```
~/.claude-monitor/debug.log
```

### Database

```
~/.claude-monitor/usage.db
```

Query directly:

```bash
sqlite3 ~/.claude-monitor/usage.db "SELECT email, last_updated FROM accounts;"
sqlite3 ~/.claude-monitor/usage.db \
  "SELECT timestamp, primary_percent FROM usage_history ORDER BY timestamp DESC LIMIT 10;"
```

## Uninstall

```bash
pkill ClaudeMonitor

launchctl unload ~/Library/LaunchAgents/com.claude-monitor.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.claude-monitor.plist 2>/dev/null

rm -rf ~/.claude-monitor
rm -rf /Applications/ClaudeMonitor.app
```

## Project Structure

```
claude-monitor/
├── menubar-app/ClaudeMonitor/   # Swift Package: macOS menu-bar app + Linux headless daemon
│   ├── Package.swift
│   ├── Assets/                     # App icon (AppIcon.icns + 1024px master PNG)
│   ├── CSQLite/                    # System-library shim mapping Linux libsqlite3
│   └── Sources/
│       ├── main.swift              # macOS entry: AppDelegate, menubar icon, popover wiring
│       ├── HeadlessMain.swift      # Linux entry (always headless)
│       ├── HeadlessRunner.swift    # UI-less poll loop (Linux daemon / --headless on macOS)
│       ├── UsageStore.swift        # SQLite store, settings, primary-account pin
│       ├── SQLiteDB.swift          # Minimal system-libsqlite3 wrapper (zero deps)
│       ├── UsagePopoverView.swift  # Summary table, sortable headers, add-account dialog
│       ├── UsageChartView.swift    # Per-account chart window
│       ├── OAuthPoller.swift       # API pings, token add/import, token rolling
│       ├── AnthropicAPI.swift      # API client
│       ├── RollTokenView.swift     # Roll Token wizard window (rotate long-lived tokens)
│       ├── TokenRoller.swift       # Revoke-all browser-console script generator
│       ├── RankingExporter.swift   # Emits ~/.claude-monitor/ranking.json for load balancers
│       ├── FileLogger.swift        # Debug logging
│       └── LinuxCompat.swift       # ObservableObject/@Published stand-ins for Linux
└── scripts/
    ├── build-macos-app.sh          # macOS release build script
    └── claude-monitor.service      # Sample systemd user unit for Linux headless mode
```

## Related Projects

- **[ccusage](https://github.com/ryoppippi/ccusage)** — CLI tool that reads
  local Claude Code JSONL logs and reports token usage / API-equivalent costs.
- **[VibePulse](https://github.com/wesm/vibepulse)** — macOS menu-bar app
  built on ccusage, showing real-time token spend.

**How they differ from Claude Monitor:**

- ccusage / VibePulse read **local Claude Code logs** → token counts and
  cost estimates.
- Claude Monitor queries **the Anthropic API via OAuth** → quota %, reset
  times, and headroom across multiple accounts.

## License

MIT
