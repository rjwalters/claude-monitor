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
- **Multi-provider.** Anthropic and OpenAI/ChatGPT (Codex) accounts sit side by
  side in the same table, each row tagged with a pixel-art provider badge. See
  [Adding an OpenAI (Codex) Account](#adding-an-openai-codex-account).
  A provider that reports no session window (ChatGPT often reports only a
  weekly one) shows "—" rather than a fabricated 0%.
- **Per-model sub-limits.** OpenAI accounts report per-model limits alongside
  the account-level window; these are stored and overlaid on the per-account
  history chart. The overlay is hidden for accounts that have none.
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
pool), use the **Bulk Import** field in the Add Account dialog
(`.env.example` in the repo is a starter template):

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

**Tokens** in these lists are Anthropic-only. They may *also* carry keyless
Codex **identity** entries — the intended-set declaration described in
[Declaring which identities a host should have](#declaring-which-identities-a-host-should-have)
— which is how you declare an intended set on a headless host with no popover
to paste into:

```env
ACCOUNT_EMAIL_3=agent3@example.com
ACCOUNT_PROVIDER_3=openai
ACCOUNT_HOME_LABEL_3=agent3
```

No `ACCOUNT_KEY_3` — there is no credential to carry. On every launch this
creates the placeholder if it isn't there and does nothing at all if it is
(including after the identity has actually been provisioned), so it is safe to
keep in a shared master list across the whole fleet.

### Adding an OpenAI (Codex) Account

ChatGPT subscription accounts (Plus/Pro, the ones Codex CLI uses) are polled
too, and no inference request is burned to read their usage.

**How the reading is taken.** There are two ways to ask, and the poller tries
them in order, preferring whichever touches the fewest credentials. This app
stores no OpenAI credential of its own (#104) — both tiers read through
whatever the Codex CLI already owns:

1. **`codex app-server`** (preferred). The app runs
   `codex -s read-only -a untrusted app-server`, speaks JSON-RPC over its stdio,
   and reads `account/rateLimits/read`. **Codex owns the credential end to end
   — this app never reads, stores, or refreshes an OpenAI token on this path.**
   Requires `codex` **0.147.0 or newer**: the method does not exist in 0.46.0
   (the version Homebrew's formula lags at), which answers `-32600` instead.
   Install the current CLI with `npm i -g @openai/codex`; it ships
   `linux-x64` / `linux-arm64` binaries, so this works on headless Linux hosts
   too.

   Homebrew ships **two** `codex` packages, and it's easy to end up on the
   wrong one: `brew install codex` installs the **formula**, which is the
   stale 0.46.0 build above. The current 0.147.0+ CLI is the **cask**. If
   you're already on the formula, switch with:

   ```bash
   brew uninstall --formula codex && brew install --cask codex
   ```

   `brew uninstall --formula` may autoremove now-unused dependencies pulled in
   only for the formula (observed: it took `ripgrep` with it on one host) —
   reinstall anything you still want separately. The cask also does **not**
   self-update in the background (`auto_updates` is `null` in its cask
   definition, unlike a cask that manages its own updater) — `brew update`
   alone won't pull in a new `codex` release, so re-running
   `brew upgrade --cask codex` periodically is on you.
2. **`auth.json` at request time.** `GET https://chatgpt.com/backend-api/wham/usage`
   — the same endpoint Codex CLI's own `/usage` command calls — with the bearer
   read fresh out of `$CODEX_HOME/auth.json` for that one request. Never written
   back, never refreshed.

A tier that is merely *unavailable* — no `codex` on the host, a `codex` too old,
no readable `auth.json` — falls through silently to the next one. Only a genuine
failure of the last tier marks the account unhealthy: there is no
stored-credential fallback below it any more, so a home that isn't logged in
(or a host with no `codex` binary and no readable `auth.json`) shows up as a
red Token dot rather than quietly polling a stale copy of the credential.

`codex` is located by absolute path, first hit wins: `$CLAUDE_MONITOR_CODEX_BIN`,
then each `PATH` entry, then `/opt/homebrew/bin`, `/usr/local/bin`,
`~/.local/bin`, `~/.npm-global/bin`. (A macOS app launched from Finder inherits
launchd's minimal `PATH`, which contains neither Homebrew's nor npm's bin
directory — hence the explicit list.) Set `CLAUDE_MONITOR_CODEX_BIN` to point at
a specific install.

**Registering an account: one `CODEX_HOME` per account.** `codex login` writes a
single `auth.json` per home directory, so **each login overwrites the previous
account's credential** — which is why monitoring more than one Codex account
never worked before. Give each account its own home and register it by that
path. The one-command way:

```bash
claude-monitor codex provision work
```

`provision <label>` collapses "pick a home, log in, register it" into one
step: it creates (or reuses, if already present) `~/.codex-<label>` as that
identity's `CODEX_HOME`, drives `codex login --device-auth` against it
interactively, and on success registers it exactly as `codex add --home`
does — reusing the same registration code, not a parallel implementation.
Re-running it for a label that's already logged in skips the login step and
just re-registers (idempotent — it will not create a second account row), and
it fails clearly, before touching anything, if `<label>` is missing or
`codex` itself can't be found. If the home is already registered to one
account but is now logged in as a *different* one, it fails rather than
silently repointing the registration — log out and back in with the intended
identity, or provision a different `<label>`.

That one command is equivalent to the three manual steps it replaces:

```bash
CODEX_HOME=~/.codex-work codex login --device-auth
claude-monitor codex add --home ~/.codex-work
```

Reach for the manual form when you want the steps decoupled — e.g. running
`codex login --device-auth` on one machine and `codex add --home` on another
that shares the same `CODEX_HOME` over a network filesystem. Either way,
`--device-auth` prints a code you paste into a browser on any machine, so this
works on a **headless Linux host** with no browser at all. Repeat for as many
accounts as you have; each poll then spawns `codex` with that account's own
`CODEX_HOME`, so one account's numbers can never land on another's row.

`codex add` **reads, copies, and stores no token.** It reads exactly one field
out of `<home>/auth.json` — the opaque `account_id` that keys the account row —
and asks `codex` itself for the identity and usage. The credential stays where
Codex CLI put it.

```bash
claude-monitor codex list
# ACCOUNT   PLAN        AUTH               CODEX_HOME
# user-3f2… pro         logged in          /Users/you/.codex-work
# user-91a… plus        needs login        /Users/you/.codex-personal
# user-77c… pro         drift → user-0d4…  /Users/you/.codex-spare
# openai-b… —           absent             (not provisioned on this host)
#   → claude-monitor codex provision agent3
```

`list` reports each home's live state: **logged in**, **needs login** (the home
exists but `codex login` hasn't been run in it), **home missing** (the directory
is gone — re-register), **drift** (see below), **absent** (see
[Declaring which identities a host should have](#declaring-which-identities-a-host-should-have)),
or **unknown** when `codex` itself is absent or too old. Both commands take
`--db <path>` to work against a throwaway store.

**drift** means that home is now logged in as a *different* account than the row
it was registered against — someone ran `codex login` in it again with another
identity. The poller has always refused to attribute such a reading to the wrong
account; `list` names it here, and names the account id the home currently holds
(or prints a bare `drift` when the home's `auth.json` carries no account id and
only the email disagrees — an email is never printed). The popover names the
same condition on the affected row: an orange dot instead of the usual
green/red/gray, with the identity and remediation in the hover text, and the
row's percentages stop updating rather than presenting stale numbers as current.
Fix it by logging the home back in as the original account, or by re-running
`codex add --home <home>` to register it as its own account — either way, the
row clears back to normal on the next poll with no restart needed.

An account with **no** registered home reads the ambient `$CODEX_HOME` (else
`~/.codex`), exactly as before — which is correct as long as it is the only
OpenAI account on the host. Add a second OpenAI account and any account still
lacking its own home stops using the ambient one (it can speak for only one of
them, and nothing says which); register its home to bring it back. (A merely
*declared* identity — see immediately below — is not a second account for this
purpose: it has no login here, so it never triggers that ambiguity.)

#### Declaring which identities a host should have

**Homes are host-local and are never synced.** `codex login` writes a
credential into one `CODEX_HOME` on one machine; copying it elsewhere is
explicitly a non-goal (see [Multi-Host Sync](#multi-host-sync) — OpenAI
supports one `auth.json` per machine and rotates the refresh token on every
use, so two hosts sharing a copy just invalidate each other). Every host must
run `codex provision <label>` for itself, once per identity.

That leaves a gap worth naming: with three Codex identities across a fleet,
a host that was only ever provisioned with two looks *exactly* like a host
that was supposed to have two. There is no missing row to notice — the
identity simply isn't there.

So the set of identities a host is *expected* to have travels on the account
copy/paste you already use. **There is no config file and no new command.**

1. On a host that has the identities, click **Copy** in the popover (or run
   the equivalent export). Anthropic accounts travel with their token as
   always; each Codex account travels as an **identity only** — its email, its
   provider, and its home *label* (the `<label>` half of `~/.codex-<label>`),
   with **no key**.
2. On the host that should have them, click **Paste**. Each identity that
   isn't already present becomes a placeholder: an account row with no
   credential and no home. (On a headless host with no popover, put the same
   keyless entries in `~/.claude-monitor/accounts.env` — see
   [Master account list](#master-account-list-auto-loaded-at-launch).)

**No credential of any kind crosses in either direction, and neither does a
home path** (a path names a user; only the label you chose travels). This is
purely a naming layer over data the app already had.

A declared-but-unprovisioned identity is then visible everywhere, without you
having to go looking:

- **In the popover** — greyed, with an `absent` badge, and every percentage
  blank. It is never auto-selected for the menu bar and never ranks as
  "most available" on its empty reading.
- **In `codex list`** — status `absent`, with the exact remediation beside it:
  `→ claude-monitor codex provision agent3`.
- **In `ranking.json`** — `"absent": true` alongside `"status": "blocked"`, so
  an external load balancer excludes it whether or not it understands the new
  key (see [Ranking Export](#ranking-export-rankingjson)).

Run the printed `codex provision <label>` on that host and the placeholder
**converts in place** into a real, polling account — same row, no duplicate,
no cleanup step. Nothing else has to be told.

Two things this deliberately does *not* do:

- **Pasting never deletes a Codex account.** An identity-only entry says "this
  host should have this identity"; it is not a claim that any identity missing
  from the payload is unwanted. A host with an *extra* provisioned identity
  keeps it, untouched and unflagged. (Anthropic entries keep their existing
  replace semantics, since they carry a full credential.)
- **Declaring an identity you already have changes nothing.** The paste
  resolves onto the existing row and leaves its home and credential alone, so
  pasting the same payload twice — or pasting it back onto the host it came
  from — is a no-op.

<details>
<summary><b>Importing a credential instead (<code>codex import</code>)</b></summary>

The original path still works, for hosts without a usable `codex` binary:

```bash
codex login
claude-monitor codex import    # or: Add Account → "Import Codex Account"
```

The importer reads `$CODEX_HOME/auth.json` when `CODEX_HOME` is set, otherwise
`~/.codex/auth.json`. Pass `--auth <path>` to read a different file. The
credential is validated against the live usage endpoint before it's stored, and
the account's email, plan, and OpenAI account id all come back in that same
response — there's no separate profile call.

Prefer `codex add`: it stores no token at all. `codex import` still stores one
transiently to validate the credential and identify the account, but a
healing migration nulls it out again on the app's very next launch (#104) —
ongoing polling reads through the tiers above, not the stored copy.

</details>

What differs from an Anthropic row once it's added:

- **Session % may be blank.** OpenAI reports its windows as
  `primary_window` / `secondary_window`, each carrying its own length, and a
  ChatGPT Pro account can legitimately report only a **weekly** window. When
  there's no session window, the Session cells show `—`. That is a real
  "unknown", not 0% — the headroom score and sorting use whichever windows
  actually exist.
- **Premium % / Extra are always `—`.** Those columns track Anthropic
  premium tiers; the Fable probe is skipped for OpenAI accounts entirely. (The
  premium column is titled "Fable %" only when every account in the table
  is Anthropic; with any OpenAI row present it shows the neutral
  "Premium %".)
- **This app stores no OpenAI credential, and renews nothing.** Usage is read
  via `codex app-server` (tier 1) or a one-time `auth.json` bearer read (tier
  2); either way the Codex CLI owns the credential and its own renewal
  entirely, and this app touches neither. The Token dot reports the outcome:
  green (a tier read succeeded), **red** (every tier failed — most often the
  home isn't logged in; hover for the reason, then run `codex login` or
  register the right home with `claude-monitor codex add --home <path>`). A
  stale OpenAI account never fails silently.

> **Historical note.** Earlier versions stored an OpenAI access/refresh token
> of their own and proactively renewed it ahead of expiry. OpenAI rotates the
> refresh token on every renewal and supports exactly one `auth.json` per
> machine, so any second copy — another host's database, or the Codex CLI's
> own `auth.json` — took turns invalidating each other's copy on every renewal
> (observed in practice: continuous `401 / refresh_token_invalidated` across
> two hosts for ~9 days). That stored-credential path is gone (#104): this app
> now only ever reads through `codex app-server` or a live `auth.json` bearer,
> so there is no copy of the credential left for it to invalidate. Full
> history in the 2026-08-15 supersession in
> [`docs/spikes/2026-07-30-codex-usage-probe.md`](docs/spikes/2026-07-30-codex-usage-probe.md).

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
│  OAuth credentials                                                       │
│    - `claude setup-token` (single, paste-in)            [anthropic]      │
│    - `.env` bulk import (ACCOUNT_EMAIL_N / ACCOUNT_KEY_N) [anthropic]    │
│    - `claude-monitor codex import` (~/.codex/auth.json)   [openai]       │
│    - `claude-monitor codex add --home <path>` (no token)  [openai]       │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ stored in
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  SQLite — ~/.claude-monitor/usage.db                                     │
│    accounts │ oauth_credentials │ usage_history │ settings               │
│    (accounts.provider / oauth_credentials.provider tag the upstream)     │
└────────────────────────────────┬─────────────────────────────────────────┘
                                 │ read by
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│  OAuthPoller — one client per provider, one shared window model          │
│    anthropic: POST /v1/messages (1-token ping) → rate-limit headers      │
│               tokens are long-lived (~1 yr); no refresh dance needed     │
│    openai:    codex app-server (preferred) or a live auth.json bearer →  │
│               rate_limit.{primary,secondary}_window; no OpenAI token is  │
│               stored or refreshed by this app (#104)                     │
│    - Each account polled once per 10 min (staggered)                     │
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

CI (`.github/workflows/build.yml`) runs on pushes to `main` and on pull requests:
two jobs build the package — macOS and a `swift:6.1` Linux container — and each
runs `ClaudeMonitor selftest`, with the Linux job also smoke-running `--once`.

**Manually re-triggering CI.** The `push`/`pull_request` webhook deliveries
that normally queue a run can silently stop firing for a stretch of time —
with no change to the workflow file, Actions settings, or repo state (see
[#66](https://github.com/rjwalters/claude-monitor/issues/66)). Since the
workflow also carries a bare `workflow_dispatch:` trigger, you can queue a run
directly against any branch (including an open PR's head) without depending
on that webhook:

```bash
gh workflow run build.yml --ref <branch-name>
```

or use the Actions tab's "Run workflow" button. If checks are missing on an
open PR and re-running doesn't help, next check (needs repo-admin access):
Settings → Actions → General (Actions permissions toggle), Settings →
Webhooks → Recent Deliveries (look for failed/missing `pull_request`
deliveries), and https://www.githubstatus.com/history for an Actions/Webhooks
incident.

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
claude-monitor --version        # print the version and exit
claude-monitor selftest         # self-check (no network/credentials); non-zero exit on failure
```

`selftest` also takes `--db <path>` (migrate and verify a **copy** of a real
database — it writes, so never point it at the live `usage.db`) and
`--wire <path>` (decode a captured `/wham/usage` body offline to re-check the
OpenAI wire contract; prints only derived numbers, never identity fields).
Run `claude-monitor selftest --help` for details.

Edits to `accounts.env` / `accounts.local.env` are picked up automatically
while the daemon runs. A sample systemd user unit is provided at
`scripts/claude-monitor.service`.

On macOS the same headless loop is available as `ClaudeMonitor --headless`
(the bare binary or the app bundle's `Contents/MacOS/ClaudeMonitor`).
`ClaudeMonitor --version` prints the version and exits on macOS with or
without `--headless` — it never launches the GUI. `--once` and `--interval`
are headless-loop flags: bare (without `--headless`) they print an error to
stderr and exit non-zero rather than launching a duplicate GUI instance, e.g.
`ClaudeMonitor --headless --once`.

## Multi-Host Sync

When multiple hosts each run their own `claude-monitor` (e.g. two Macs + a
fleet of headless Linux workers), account records and OAuth credentials added
on one host don't automatically appear on the others. `claude-monitor
accounts export` / `import` is the blessed, headless-safe way to converge
them — no GUI required, works identically on macOS and Linux:

```bash
# On the source host: dump account records + credentials to a file (0600).
claude-monitor accounts export --output accounts.json

# Copy it to each destination host over a trusted channel (scp, etc.),
# then converge that host's own usage.db:
claude-monitor accounts import accounts.json
```

- **What's synced:** Anthropic account identity (id, name, email, plan) and
  OAuth credentials (access/refresh tokens, expiry, scopes, plan tier). Usage
  history, rankings, and poll status are **not** synced — those stay local to
  each host's own polling.
- **Codex/OpenAI accounts are host-local and excluded on purpose:** `export`
  never emits one, and `import` skips (rather than errors on) any it finds in
  a bundle from an older version. Codex usage is read via `codex app-server`
  against a per-account `CODEX_HOME`, and OpenAI supports exactly one
  `auth.json` per machine — shipping a copy of that credential to another host
  only guarantees the two hosts take turns invalidating each other's copy.
  Register a Codex account on each host instead: `claude-monitor codex
  provision <label>`. To carry across *which identities a host should have*
  (names only, still no credentials), use the popover's Copy/Paste — see
  [Declaring which identities a host should have](#declaring-which-identities-a-host-should-have).
- **Idempotent, upsert-by-email:** `import` matches accounts by email
  (falling back to id when email is absent), creates any account it doesn't
  find locally, and updates the rest — except it **never regresses a newer
  local record**: if the local `last_updated` is at least as recent as the
  imported one, that account is left untouched. Safe to re-run against the
  same file, and safe to import an older export after newer local polls.
  `--dry-run` previews the account count without writing anything.
- **Credentials are secrets:** the export is plaintext JSON containing live
  OAuth tokens. `--output <path>` writes it with `0600` permissions and the
  command prints a warning either way; without `--output` (stdout, e.g. for
  `> accounts.json`) permissions aren't set for you — `chmod 600` the result,
  transfer it over a trusted channel, and delete it once every destination
  host has imported. Full at-rest/in-transit encryption (age, openssl) is a
  natural next step but out of scope for the first pass here.
- **No `--headless` flag needed** — `accounts export`/`import` are one-shot
  operations, reachable directly on both platforms even from the macOS GUI
  build: `ClaudeMonitor accounts export ...`.

Run `claude-monitor accounts --help` for the full flag list.

## Ranking Export (`ranking.json`)

After every poll cycle the app writes a small, **non-secret**, email-keyed
snapshot to `~/.claude-monitor/ranking.json` for external multi-account load
balancers (notably `loom-daemon`, which uses it to pick a token). It's written
atomically, so a reader never sees a partial document.

```jsonc
{
  "schema": 1,
  "generated_at": "2026-07-30T18:00:00Z",
  "accounts": [
    {
      "email":       "you@example.com",   // the join key
      "provider":    "anthropic",         // "anthropic" | "openai"
      "plan":        "max_20x",
      "status":      "available",         // available | rate_limited | exhausted | blocked
      "utilization": { "5h": 0.12, "7d": 0.44 },   // 0.0–1.0
      "resets":      { "5h": "…Z", "7d": "…Z" },
      "models":      { "fable": { "utilization": 0.30 } },   // optional
      "updated_at":  "2026-07-30T17:58:00Z"
    },
    {
      "email":       "you@example.com",
      "provider":    "openai",
      "plan":        "pro",
      "status":      "available",
      "utilization": { "7d": 0.14 },      // note: no "5h" key — see below
      "resets":      { "7d": "…Z" },
      "updated_at":  "2026-07-30T17:58:00Z"
    },
    {
      "email":       "agent3@example.com",
      "provider":    "openai",
      "status":      "blocked",           // never routable
      "absent":      true                 // …because it isn't set up on this host
      // no utilization / resets / updated_at: nothing has ever been read here
    }
  ]
}
```

**Schema change for consumers (added with OpenAI support):**

- **`provider` is new and additive.** It is emitted for *every* account and is
  `"anthropic"` or `"openai"`; accounts that predate multi-provider support
  report `"anthropic"`. `schema` stays **1** on purpose — the version number
  tracks breaking changes, and adding an optional key breaks nobody. A consumer
  that ignores `provider` behaves exactly as it did before. Treat an unrecognized
  future value as "some other provider" rather than rejecting the document.
- **`utilization["5h"]` can be absent on an `openai` account.** The ChatGPT
  usage endpoint may report a weekly window and no session window at all.
  A missing key means **unknown**, not `0.0` — reading it as zero would make an
  account look like it has full session capacity. The same applies to
  `resets["5h"]`. (Anthropic accounts always report both windows.)
- **`absent` is new and additive.** It appears **only** on an OpenAI identity
  this host is expected to have but was never provisioned with (see
  [Declaring which identities a host should have](#declaring-which-identities-a-host-should-have));
  the key is omitted entirely for every other account, so nothing changes for a
  consumer that has never heard of it. Such an account is emitted with
  `"status": "blocked"` — an existing value that already means "do not route
  work here" — and with **no** `utilization`, `resets`, or `updated_at`, since
  nothing has ever been read for it locally. A consumer that ignores `absent`
  therefore still excludes it correctly; one that reads it can tell "the
  credential here is broken" (`blocked`) apart from "this host was never set up
  for that identity" (`blocked` + `absent`), which is what makes a fleet-wide
  "who is missing which account?" view possible at all. `schema` stays **1**.
- Accounts with a `NULL` email are still excluded entirely; `email` remains the
  sole join key, and it is not unique across providers — one person's Anthropic
  and OpenAI accounts can share an address, distinguished by `provider`.
- No credential material ever appears in this file, and neither does a
  `CODEX_HOME` path.

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

**`accounts` table contract for external consumers:** `email` is the stable
join key external tooling should key off of — notably `loom-daemon tokens
import-from-monitor`, which matches accounts by `email` to build its token
pool. `account_name` is a free-text, user-editable display label/alias and is
**not** guaranteed to be an address (though it often is, since renaming an
account to its own email is a common way to tell accounts apart in the UI).
The app backfills `email` from `account_name` whenever the profile-derived
email is unavailable but the label is itself a well-formed address — both at
add/rename time and via a one-time healing migration on launch — so no account
with valid credentials should persist indefinitely with `email = NULL`. If you
ever see one, it means `account_name` isn't address-shaped either; there's no
address for external tooling to recover.

## Uninstall

```bash
pkill ClaudeMonitor

launchctl unload ~/Library/LaunchAgents/com.claude-monitor.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.claude-monitor.plist 2>/dev/null

rm -rf ~/.claude-monitor
rm -rf /Applications/ClaudeMonitor.app
```

### Upgrading from pre-1.8

Versions before 1.8 shipped a Node CLI (`dist/cli.js`) that was removed in the v1.8 Swift rewrite. Its build artifacts are untracked, so they linger in old checkouts and fail confusingly if run (e.g. `node dist/cli.js` errors with `ERR_MODULE_NOT_FOUND` for `commander`). Clean them up:

```bash
rm -rf dist node_modules
```

## Project Structure

```
claude-monitor/
├── menubar-app/ClaudeMonitor/   # Swift Package: macOS menu-bar app + Linux headless daemon
│   ├── Package.swift
│   ├── Assets/                     # App icon (AppIcon.icns + 1024px master PNG + generation recipe)
│   ├── CSQLite/                    # System-library shim mapping Linux libsqlite3
│   └── Sources/
│       ├── main.swift              # macOS entry: AppDelegate, menubar icon, popover wiring
│       ├── HeadlessMain.swift      # Linux entry (always headless)
│       ├── HeadlessRunner.swift    # UI-less poll loop (Linux daemon / --headless on macOS)
│       ├── AccountSync.swift       # accounts export/import: multi-host record + credential sync
│       ├── AccountSyncCLI.swift    # `claude-monitor accounts export|import` CLI surface
│       ├── CLIArgs.swift           # Shared --db/--help parsing for the subcommand CLIs
│       ├── UsageStore.swift        # SQLite store, settings, primary-account pin
│       ├── AccountFreshness.swift  # Single staleness rule shared by display/ranking paths
│       ├── SQLiteDB.swift          # Minimal system-libsqlite3 wrapper (zero deps)
│       ├── UsagePopoverView.swift  # Summary table, sortable headers, add-account dialog
│       ├── PercentSeverity.swift   # Shared >95 / >=90 severity bands for popover, chart, menubar
│       ├── UsageChartView.swift    # Per-account chart window
│       ├── OAuthPoller.swift       # Per-provider polling, token add/import/refresh
│       ├── AnthropicAPI.swift      # Anthropic client (ping + rate-limit headers)
│       ├── OpenAIAPI.swift         # OpenAI/Codex client (wham/usage + token refresh)
│       ├── CodexAppServer.swift    # Codex app-server JSON-RPC client (usage with no stored credential)
│       ├── CodexCLI.swift          # `claude-monitor codex provision|add|list|import` CLI surface
│       ├── RateLimitWindow.swift   # Provider-agnostic window/snapshot model
│       ├── UsageProviderClient.swift # UsageProviderClient protocol + credentials
│       ├── SelfTest.swift          # `claude-monitor selftest` portable-core assertions
│       ├── RollTokenView.swift     # Roll Token wizard window (rotate long-lived tokens)
│       ├── TokenRoller.swift       # Revoke-all browser-console script generator
│       ├── RankingExporter.swift   # Emits ~/.claude-monitor/ranking.json for load balancers
│       ├── FileLogger.swift        # Debug logging
│       ├── NaturalSort.swift       # Hybrid lexical/numeric ordering (agent-10 after agent-9)
│       └── LinuxCompat.swift       # ObservableObject/@Published stand-ins for Linux
├── scripts/
│   ├── build-macos-app.sh          # macOS release build script
│   └── claude-monitor.service      # Sample systemd user unit for Linux headless mode
├── docs/spikes/                 # Investigation write-ups (e.g. the OpenAI usage-endpoint probe)
├── .github/workflows/build.yml  # CI: build + selftest on macOS and Linux
├── build/                       # Build output (gitignored): ClaudeMonitor.app + .zip
├── CHANGELOG.md                 # Release history
├── CLAUDE.md                    # Development notes (build/install sequence, invariants)
├── WORK_LOG.md, WORK_PLAN.md    # Loom-maintained work history and plan (regenerated by the Guide role)
├── .env.example                 # Sample accounts.env for bulk import
├── window.png, plot_window.png  # README screenshots
├── loom.sh, package.json        # Loom orchestration workspace files (not part of the app)
└── .loom/, .claude/, .gitattributes  # Loom + Claude Code tooling installs
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
