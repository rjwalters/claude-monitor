#!/usr/bin/env bash
#
# Scratch probe for issue #26 (part of the multi-provider epic, #25).
#
# NOT YET LIVE-VERIFIED. This script encodes the best hypothesis this spike
# could derive from static analysis of the Codex CLI binary (see
# docs/spikes/2026-07-30-codex-usage-probe.md) about how to fetch ChatGPT
# subscription usage/rate-limit data using a Codex CLI OAuth credential. It
# has deliberately NOT been run against a live account as part of this spike,
# because the only credential available at spike time belonged to a primary
# personal account, and the issue this script was written for explicitly
# requires a disposable/low-value test account instead.
#
# SAFETY:
#   - Only run this against a disposable/test ChatGPT Plus/Pro account that
#     you are authorized to probe with. Do NOT run it against a primary
#     account.
#   - This script never echoes token values. It reads the access token
#     directly into a curl Authorization header without passing through any
#     command that would print it (no `echo $TOKEN`, no `set -x`).
#   - If you add debug output while iterating, redact tokens and any PII
#     (email, name, account UUIDs) before sharing output -- including inside
#     an agent transcript. See the write-up's "Credential situation" section
#     for the failure mode this guards against.
#
# USAGE:
#   CODEX_HOME="${CODEX_HOME:-$HOME/.codex}" ./codex-usage-probe.sh
#
# Requires: curl, jq (for parsing ~/.codex/auth.json and pretty-printing
# response bodies; falls back to raw output if jq is unavailable).

set -euo pipefail

CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
AUTH_JSON="$CODEX_HOME/auth.json"

if [[ ! -f "$AUTH_JSON" ]]; then
  echo "error: no Codex CLI credential at $AUTH_JSON" >&2
  echo "  Install/log in with a DISPOSABLE test account: 'codex login'" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to read $AUTH_JSON safely (avoids shell-parsing JSON by hand)" >&2
  exit 1
fi

ACCESS_TOKEN="$(jq -r '.tokens.access_token' "$AUTH_JSON")"
ACCOUNT_ID="$(jq -r '.tokens.account_id' "$AUTH_JSON")"

if [[ -z "$ACCESS_TOKEN" || "$ACCESS_TOKEN" == "null" ]]; then
  echo "error: could not read tokens.access_token from $AUTH_JSON" >&2
  exit 1
fi

echo "== Candidate 1: https://chatgpt.com/backend-api/codex/usage (chatgpt-account-id header) =="
HTTP_STATUS=$(curl -sS -o /tmp/codex-usage-probe-1.json -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "chatgpt-account-id: $ACCOUNT_ID" \
  -H 'Content-Type: application/json' \
  "https://chatgpt.com/backend-api/codex/usage" || echo "CURL_FAILED")
echo "status: $HTTP_STATUS"
if command -v jq >/dev/null 2>&1 && [[ -s /tmp/codex-usage-probe-1.json ]]; then
  echo "response field names (values redacted):"
  jq 'walk(if type == "number" or type == "string" then "<redacted>" else . end)' \
    /tmp/codex-usage-probe-1.json 2>/dev/null || cat /tmp/codex-usage-probe-1.json
fi
echo

echo "== Candidate 2: https://chatgpt.com/backend-api/wham/usage (no account-id header) =="
HTTP_STATUS=$(curl -sS -o /tmp/codex-usage-probe-2.json -w '%{http_code}' \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  "https://chatgpt.com/backend-api/wham/usage" || echo "CURL_FAILED")
echo "status: $HTTP_STATUS"
if command -v jq >/dev/null 2>&1 && [[ -s /tmp/codex-usage-probe-2.json ]]; then
  echo "response field names (values redacted):"
  jq 'walk(if type == "number" or type == "string" then "<redacted>" else . end)' \
    /tmp/codex-usage-probe-2.json 2>/dev/null || cat /tmp/codex-usage-probe-2.json
fi
echo

cat <<'EOF'
If both candidates 404/401: the real route wasn't guessed correctly from
static analysis alone. Next step is a traffic capture of Codex CLI's own
`/usage` command against the SAME disposable test account, e.g.:

  mitmproxy -p 8080 &
  HTTPS_PROXY=http://127.0.0.1:8080 SSL_CERT_FILE=<mitmproxy-ca.pem> codex
  # inside the TUI: run /usage, then inspect the mitmproxy flow for the
  # exact request path, headers, and response body field names.

Once the real route + fields are confirmed, update
docs/spikes/2026-07-30-codex-usage-probe.md and this script accordingly
before epic phase 2 implements the production OpenAI OAuthPoller path.
EOF

rm -f /tmp/codex-usage-probe-1.json /tmp/codex-usage-probe-2.json
