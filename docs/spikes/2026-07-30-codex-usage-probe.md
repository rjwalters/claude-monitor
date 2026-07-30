# Spike: can a cheap authenticated probe read ChatGPT/Codex subscription usage?

Issue: #26 (part of the multi-provider epic, #25)
Date: 2026-07-30

## Question

The app's Anthropic polling sends a 1-token Haiku message and reads the
`anthropic-ratelimit-unified-*` response headers back. Is there an OpenAI
equivalent for **ChatGPT subscription accounts** (Plus/Pro, as used by Codex
CLI): a minimal authenticated request whose response carries session-window
and weekly-window usage/reset data?

> **UPDATE 2026-07-30 (live-verified).** The probe below was subsequently run
> against a real ChatGPT Pro credential and **succeeded (HTTP 200)**. The
> answer is now a confirmed **yes**, but the wire contract differs from the
> static-analysis hypothesis in several load-bearing ways. See
> "Live verification" at the end of this document — that section, not the
> static analysis below, is the authoritative contract for epic phase 2.

## Short answer

**Very likely yes, but not live-verified in this spike.** Static analysis of
the shipped Codex CLI binary (v0.146.0) shows Codex CLI itself calls a
dedicated usage/rate-limit endpoint and parses a response shape that is a very
close analog of what we need — a list of rate-limit windows, each with a
percent-used figure, a window size in minutes (letting the client tell a ~5h
window apart from the weekly window), and a reset timestamp. That is enough
to build the `AnthropicAPI`-equivalent provider client with high confidence
in the target shape.

What is **not** yet confirmed by live traffic is: the exact request path
concatenation (base host + route), the exact JSON field names on the wire
(the binary only gives us the internal Rust struct field names, which usually
but not always match the wire JSON), and the real-world cost/rate-limit
impact of calling it. See "What wasn't done, and why" below.

## Credential situation on this host

`~/.codex/auth.json` exists on this machine (Codex CLI 0.146.0 is installed
and logged in). Its structure (`auth_mode`, `tokens.{id_token,access_token,
refresh_token,account_id}`, `last_refresh`) was inspected with redaction —
the raw token strings and PII (email, name) were **not** printed to this
write-up.

Decoding the (already-issued, not modified) JWT claims to understand token
shape revealed this is the **operator's personal, primary ChatGPT Pro
account** (a personal Gmail address, `role: owner` on a `Personal`
organization). The issue explicitly says:

> Use a low-value/test account, NOT a primary account.

Because the only credential available on this host is disqualified by that
instruction, **no live network probe was made against `chatgpt.com` /
`api.openai.com` with this credential.** This spike is therefore functionally
in the same position as "no usable test credential" even though a credential
file exists. A dedicated low-value/disposable ChatGPT account should be
provisioned before the live-verification step below is attempted.

(Process note for future spikes: when decoding JWT claims for structural
inspection, redact **nested** PII fields too, not just top-level keys — a
first redaction pass in this session missed the `email`/`name` claims nested
under `https://api.openai.com/profile` and they briefly appeared in the
agent's own transcript before being caught. No credential value was leaked,
but it is exactly the failure class #16 warned about. Fixed for the second
pass; flagging here so the next spike's redaction helper accounts for nested
paths from the start.)

## What was done instead: static analysis of the Codex CLI binary

Since Codex CLI's own `/usage` TUI command displays 5h/weekly percentages,
the binary itself has to parse *some* wire response into that shape. Rather
than emit new authenticated network traffic, this spike ran `strings -a` over
the installed binary (`/opt/homebrew/Caskroom/codex/0.146.0/bin/codex`, an
aarch64 Mach-O) and grepped for the internal type names, JSON field names,
and route strings the compiler embedded. This is fully reproducible by
anyone with Codex CLI installed and requires no network access or
credentials:

```bash
strings -a "$(readlink -f "$(command -v codex)")" > /tmp/codex_strings.txt
grep -n "RateLimitWindow\|GetAccountRateLimits\|GetAccountTokenUsage" /tmp/codex_strings.txt
```

### Response shape (from embedded Rust/TS type metadata)

```
GetAccountRateLimitsResponse
  rate_limits                  # Vec<RateLimitWindow>
  rate_limits_by_limit_id       # map, keyed by a rate-limit id
  rate_limit_reset_credits      # optional reset-credit info (see below)

RateLimitWindow (3 fields)
  used_percent                  # f64/percent
  window_minutes                # window size in minutes — e.g. ~300 (5h) vs ~10080 (7d)
  resets_at                     # reset timestamp

GetAccountTokenUsageResponse
  summary
  daily_usage_buckets           # Vec<AccountTokenUsageDailyBucket>

AccountTokenUsageDailyBucket
  start_date
  tokens
```

`RateLimitWindow.window_minutes` is the key field: it is exactly the
mechanism that would let a client tell the "5h" window from the "weekly"
window apart in a single response array, without two separate calls — a
close structural analog of Anthropic's paired
`anthropic-ratelimit-unified-{5h,7d}-*` headers, just shaped as an array of
windows in a JSON body instead of a family of response headers.

### Error strings confirming a dedicated, authenticated fetch (not header piggyback)

```
chatgpt authentication required to read rate limits
codex account authentication required to read rate limits
failed to fetch codex rate limits: no snapshots returned
chatgpt authentication required to read token usage
codex account authentication required to read token usage
```

This is an architecturally different approach from Anthropic's: Anthropic
piggybacks rate-limit state on the headers of every response (including a
throwaway 1-token completion); OpenAI/ChatGPT appears to expose it via a
**separate, dedicated endpoint** the CLI calls independently (Codex CLI's own
`/usage` TUI command triggers it). That's good news for probe cost — it
implies we would not need to burn a completion request at all, just call the
usage endpoint directly — but the exact cost/rate-limit accounting of calling
it is unverified (see below).

### Candidate route and host strings

```
https://chatgpt.com/backend-api/codex      # explicit full-URL constant found in the binary
/api/codex/usage                            # route name, paired with:
/wham/usage                                 # ...an alternate route name
/api/codex/rate-limit-reset-credits
/wham/rate-limit-reset-credits
/api/codex/rate-limit-reset-credits/consume
/wham/rate-limit-reset-credits/consume
```

Each route name shows up in **two** forms — an `/api/codex/...` form and a
`/wham/...` form — which lines up with the two auth-mode error strings above
("chatgpt authentication" vs "codex account authentication"): the CLI
appears to route the same logical call through a different path prefix
depending on whether the session is ChatGPT-OAuth-authenticated (this repo's
case, `auth_mode: "chatgpt"`) or authenticated via an OpenAI-platform/"codex
account" identity. **The exact base-host + path concatenation actually used
for the ChatGPT-OAuth case was not confirmed** — static strings show the
pieces but not how the HTTP client joins them at runtime. A `chatgpt-account-id`
HTTP header name is also present in the binary and mirrors the
`chatgpt_account_id` claim already present in the id/access token, so it is
very likely sent per-request the way Anthropic's calls carry account
identity in the bearer token alone.

### Auth mechanics — the significant departure from the Anthropic model

`~/.codex/auth.json` holds three JWTs plus a UUID:

| Field | Purpose | Lifetime (this token) |
|---|---|---|
| `access_token` | Bearer token for API calls, `aud: https://api.openai.com/v1` | **10 days** exactly (`exp - iat` = 864000s) |
| `id_token` | Carries profile + `https://api.openai.com/auth.*` claims (plan type, chatgpt_account_id, org) | **1 hour** (`exp - iat` = 3600s) |
| `refresh_token` | Opaque `rt.1.…` token | Not JWT-encoded; lifetime unknown from the token itself |
| `account_id` | UUID, matches the `chatgpt_account_id` claim | n/a |

Refresh flow (confirmed from `~/.codex/log/codex-login.log`, which only ever
recorded the login/refresh host, not token contents):

```
POST https://auth.openai.com/oauth/token
```

This is the single most important structural difference from the app's
current Anthropic-only assumption: Anthropic's `sk-ant-oat01` tokens are
long-lived (~1yr), so `Account`/`OAuthPoller` today assume a token is usable
indefinitely until explicitly revoked. A `provider: openai` account with a
**10-day access token** requires the poller to actively refresh well before
every poll cycle assumes staleness — this is a "must design for" item for
epic phase 2 (the `Account` schema needs a `refresh_token` + `token_expires_at`
field, not just a bearer string), not an optional nicety.

## What wasn't done, and why

- **No live HTTP call was made** to `chatgpt.com`/`api.openai.com` with the
  credential on this host, because it is a primary personal account and the
  issue explicitly disallows that.
- **No mitmproxy traffic capture** was set up for the same reason — capturing
  `codex`'s own traffic during normal use would also exercise the primary
  account's live session.
- The exact endpoint path, wire JSON field names (vs. the internal Rust
  field names found here), and per-call cost/quota impact are therefore
  **unconfirmed**, pending a disposable test account.

## Reproducible next step (for whoever has a disposable ChatGPT Plus/Pro test account)

A ready-to-run, **not yet executed**, probe script is included at
[`docs/spikes/codex-usage-probe.sh`](codex-usage-probe.sh). It:

1. Reads `access_token` out of `~/.codex/auth.json` (or `$CODEX_HOME/auth.json`)
   without ever echoing it.
2. Tries the two most likely candidate requests derived from the static
   analysis above (`https://chatgpt.com/backend-api/codex/usage` and a
   `chatgpt-account-id` header variant), printing only the HTTP status code
   and response body shape (field names / types), not raw token values.
3. Leaves clear `TODO`s for capturing the *actual* route via mitmproxy
   (`codex` itself, run once with a proxy env var, against the test account)
   if the static-analysis guesses miss.

Run it only against a disposable/test account, per the issue's own guidance.

## Recommendation

**Proceed to epic phase 2 (provider abstraction), conditionally.**

The static evidence is strong enough to design the `provider` abstraction
and `Account` schema now — in particular:

- Model the response as an array of rate-limit windows keyed by
  `window_minutes` (or a small enum derived from it: `session` / `weekly`),
  each carrying `used_percent` + `resets_at`, mirroring
  `RateLimitWindow` — this generalizes cleanly to a shared
  `RateLimitWindow`-shaped Swift type both providers populate.
- Extend `Account` (or a provider-specific side table) with
  `token_expires_at` and treat `refresh_token`-based renewal as mandatory
  infrastructure for OpenAI accounts, not best-effort — a 10-day access
  token will expire mid-epic if the poller doesn't refresh proactively.
- **Before shipping the real OpenAI `OAuthPoller` network path**, add a
  live-verification checkpoint using a disposable test account to confirm
  the exact endpoint and wire field names this document could not confirm
  statically. Do not assume the exact route string in this document is
  correct without that check — treat it as a strong hypothesis, not a
  verified contract.

## Live verification (2026-07-30) — AUTHORITATIVE

The operator judged a disposable account unnecessary: the probe is a
**read-only GET** against the same endpoint Codex CLI's own `/usage` command
already calls with this credential, so it carries no account risk. The probe
script was run as written. Results below supersede the static-analysis
hypotheses above wherever they disagree.

### The working call

```
GET https://chatgpt.com/backend-api/wham/usage
Authorization: Bearer <access_token from ~/.codex/auth.json>
```

- **200 OK.** No `chatgpt-account-id` header required — the bearer token alone
  carries account identity, exactly as Anthropic's does.
- The **`/backend-api/codex/usage` variant returned 403** — a Cloudflare bot
  challenge (an interstitial HTML page, not a JSON error). The `/wham/` prefix
  is the one to use; the `/api/codex/` prefix appears to be browser-fronted and
  bot-protected. This inverts the naive guess that `/api/codex/…` was the
  "real" route.

### Actual response shape (identity values redacted)

```jsonc
{
  "user_id": "…", "account_id": "…", "email": "…", "plan_type": "…",
  "rate_limit": {
    "allowed": true,
    "limit_reached": false,
    "primary_window": {
      "used_percent": 14,
      "limit_window_seconds": 604800,   // 7d
      "reset_after_seconds": 524971,
      "reset_at": 1785967226            // unix epoch seconds
    },
    "secondary_window": null
  },
  "code_review_rate_limit": null,
  "additional_rate_limits": [
    { "limit_name": "GPT-5.3-Codex-Spark", "metered_feature": "codex_bengalfox",
      "rate_limit": { /* same shape */ } }
  ],
  // other top-level keys: credits, promo, spend_control,
  // rate_limit_reset_credits, rate_limit_reached_type
}
```

### Corrections to the static analysis

| Static-analysis hypothesis | Actual wire contract |
|---|---|
| `rate_limits`: an **array** of windows | `rate_limit.primary_window` / `.secondary_window` — **named fields**, not an array |
| `window_minutes` | **`limit_window_seconds`** (seconds, not minutes) |
| `resets_at` | **`reset_at`** (unix epoch seconds), plus `reset_after_seconds` |
| — | `allowed` / `limit_reached` booleans (a direct "are you cut off" signal Anthropic's headers don't give us) |
| — | Identity comes back in the same call: `email`, `plan_type`, `account_id` |

`used_percent` survives unchanged and is the field the headroom score needs.

### Two genuinely new findings

1. **The window model is not a guaranteed 5h+weekly pair.** On this Pro
   account, `primary_window` was the **weekly** window (`604800`s) and
   `secondary_window` was **null** — no 5h window was reported at all. Do
   **not** hard-code "primary = session, secondary = weekly". Derive the window
   kind from `limit_window_seconds` and tolerate a null second window. This
   matters for the popover: an OpenAI account may legitimately have no session
   figure to show.
2. **Per-model sub-limits are a first-class part of the response.**
   `additional_rate_limits[]` carries named per-model/feature limits (here
   `GPT-5.3-Codex-Spark` / `codex_bengalfox`), each with the identical
   `rate_limit` shape. This is a close analog of this app's existing per-model
   Fable tracking, and is a better-structured source than what Anthropic
   exposes.

### Still unverified

- Cost/quota impact of polling this endpoint (it returned instantly and is
  what the CLI's own `/usage` hits, so it is very likely free, but no
  before/after quota comparison was made).
- The `refresh_token` flow against `auth.openai.com/oauth/token` was **not**
  exercised — the 10-day access-token lifetime finding above still stands as
  the phase-2 design driver, but the refresh call itself remains untested.
- Whether `secondary_window` populates on plans/accounts that do have an
  active 5h window (see finding 1) — worth re-probing when a session window is
  actually in use.

## References

- Codex CLI: `codex-cli 0.146.0`, installed via `brew install --cask codex`
  at `/opt/homebrew/Caskroom/codex/0.146.0/bin/codex`.
- `~/.codex/auth.json` — Codex CLI's ChatGPT-OAuth credential store.
- `~/.codex/log/codex-login.log` — confirms `https://auth.openai.com/oauth/token`
  as the refresh endpoint.
- Issue #16 (this repo) — the transcript-leak incident this spike's
  redaction discipline is following.
