# macOS TCC + a stable codesign identity (#4244)

Ad-hoc signing (the `loom-daemon` default, #4016) pins a legible
`--identifier`, but TCC (Transparency, Consent, and Control — the Privacy &
Security prompts) anchors a grant to the binary's **designated requirement**,
which for an ad-hoc signature is a **cdhash-only** DR. Every
`loom-daemon-update.sh` self-update roll rebuilds the binary (build.rs embeds
the git commit and build time), producing a new cdhash — so any TCC grant
made to the previous build silently evaporates and the operator is
re-prompted. See [`daemon-reference.md` → "Why Full Disk Access is never the
right answer"](daemon-reference.md) for the full measured writeup.

`LOOM_CODESIGN_IDENTITY` (env, or the `codesign.identity` config key — the
repo's standard env > config > default precedence) is the opt-in fix: point
it at a certificate already in the keychain and `provision-daemon.sh` signs
the daemon binary with THAT certificate's chain instead of ad-hoc. A
certificate-anchored DR (`identifier "X" and certificate leaf = H"…"`)
survives a rebuild — the identity, not the per-build hash, is what's pinned.
Unset (or an identity `security find-identity -v -p codesigning` doesn't
list) falls back to the ad-hoc path unchanged — this is entirely opt-in and
every non-Darwin / no-`codesign` host is unaffected.

## One-time setup: a self-signed "Code Signing" certificate

You only need a certificate that satisfies the macOS `codeSign` policy — a
paid Developer ID is not required for this local, single-machine use case.

### Option A — Certificate Assistant (GUI)

1. **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name it something recognizable (e.g. `Loom Local Signing`).
3. **Identity Type**: Self Signed Root. **Certificate Type**: **Code Signing**.
4. Let it install into the login keychain.
5. Verify it resolves: `security find-identity -v -p codesigning` should list it.

### Option B — openssl + `security import` (scriptable)

```bash
# 1. Generate a self-signed cert + key.
openssl req -x509 -newkey rsa:2048 -keyout loom-signing.key \
  -out loom-signing.crt -days 3650 -nodes \
  -subj "/CN=Loom Local Signing" \
  -addext "extendedKeyUsage=codeSigning"

# 2. Package as PKCS#12. OpenSSL 3's default export format fails
#    `security import`'s MAC verification ("MAC verification failed") --
#    the `-legacy` flag is required for a keychain-compatible export.
openssl pkcs12 -export -legacy -in loom-signing.crt -inkey loom-signing.key \
  -out loom-signing.p12 -passout pass:changeit

# 3. Import into the login keychain, trusting codesign(1) as an anchor so
#    later signing is NON-INTERACTIVE (no GUI trust prompt) -- required for
#    the #4055 self-update loop to sign unattended.
security import loom-signing.p12 -k ~/Library/Keychains/login.keychain-db \
  -P changeit -T /usr/bin/codesign

# 4. Trust the cert for the codeSign policy specifically (also avoids an
#    interactive prompt on first use).
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db \
  loom-signing.crt

rm -f loom-signing.p12 loom-signing.key   # keep the .crt if you want a record
```

Both quirks above were hit and confirmed on a real host (2026-07-28):
`openssl pkcs12 -export` without `-legacy` fails `security import` with "MAC
verification failed", and `-T /usr/bin/codesign` at import time is what lets
`codesign` sign later without prompting — provided the login keychain is
unlocked in the user session (true for any interactive login; a headless/CI
context should keep using the ad-hoc default instead).

## Using it

```bash
export LOOM_CODESIGN_IDENTITY="Loom Local Signing"
./.loom/scripts/cli/loom-daemon-update.sh     # or any provision-daemon.sh caller
codesign -dvv ~/.local/bin/loom-daemon        # Authority=Loom Local Signing, no adhoc flag
```

Or persist it in `.loom/config.json` (or `.loom-local/local.json` for a
machine-local, ungitted override):

```json
{
  "codesign": { "identity": "Loom Local Signing" }
}
```

## Grant the daemon identity, not Terminal

Work spawned from an interactive terminal shell — in-session
`spawn-claude.sh`, a hand-run `nohup loom-daemon …`, a debug daemon started
from a worktree — attributes its TCC requests to the **terminal app**, not to
`loom-daemon`. Granting broad file access there extends that grant to
*everything ever run in that terminal*, forever, which is both a bigger
attack surface than intended and does nothing to fix the actual rebuild
churn.

Prefer dispatching through the daemon itself — `loom-daemon dispatch` /
`mcp__loom__dispatch_sweep` — so any TCC prompt a sweep child triggers is
attributed to the `loom-daemon` binary (launchd already attributes children
of a supervised job to the parent binary; no plist change is needed for
this). If a grant is ever genuinely needed, add it to the `loom-daemon` row
specifically (`~/.local/bin/loom-daemon`) rather than to Terminal — and, per
the daemon-reference writeup, first double check the access really needs to
be there at all, since the daemon's legitimate working set is scoped and
FDA/broad grants are rarely the right fix.

If you re-sign the binary with a stable identity after previously granting
Terminal (or a stale ad-hoc `loom-daemon` row), remove the stale row from the
relevant Privacy & Security pane and re-add the current binary path — the
grant will then persist across rolls instead of silently evaporating.
