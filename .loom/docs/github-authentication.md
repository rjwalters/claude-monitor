# GitHub Authentication Guide

Loom uses the `gh` CLI for all GitHub interactions — label management, PR creation, reviews, merges, and issue coordination. By default, `gh auth login` grants access to all repositories the authenticated user can reach. For tighter security, you can scope Loom's access to a single repository using a fine-grained personal access token (PAT).

## Quick Start

```bash
# 1. Create a fine-grained PAT (see steps below)
# 2. Export it before running Loom
export GH_TOKEN=github_pat_xxx

# 3. Verify
gh auth status
```

## Required Token Permissions

A fine-grained PAT scoped to the target repository needs these permissions:

| Permission | Level | Used By | Purpose |
|---|---|---|---|
| Issues | Read & Write | Builder, Curator, Champion, Shepherd | Label coordination, issue creation and editing |
| Pull requests | Read & Write | Builder, Judge, Champion, Doctor | PR creation, reviews, merges |
| Contents | Read & Write | Builder, Champion | Push branches, merge PRs, delete branches |
| Checks | Read | Auditor, Judge | CI status verification |
| Metadata | Read | All roles | Implicit, always granted with any other permission |

## Creating a Fine-Grained PAT

1. Go to [GitHub token settings](https://github.com/settings/tokens?type=beta)
2. Click **Generate new token**
3. Set a descriptive name (e.g., `loom-<repo-name>`)
4. Set an expiration (90 days recommended; renew before it expires)
5. Under **Repository access**, select **Only select repositories** and choose the target repo
6. Under **Permissions**, expand **Repository permissions** and set:
   - **Contents**: Read and write
   - **Issues**: Read and write
   - **Pull requests**: Read and write
   - **Checks**: Read-only
7. Click **Generate token** and copy the value immediately — it won't be shown again

## Using the Token

The `gh` CLI checks for `GH_TOKEN` (or `GITHUB_TOKEN`) before using its default credential store. Set the variable in the shell session where Loom runs:

```bash
# Option A: Export in current session
export GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxx

# Option B: Add to shell profile (~/.zshrc, ~/.bashrc)
export GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxx

# Option C: Use a secrets manager or .env file (not committed)
source .env  # where .env contains: export GH_TOKEN=github_pat_xxx
```

When using Daemon Mode, set the variable before launching the daemon so all spawned terminals inherit it.

## Verifying Authentication

```bash
# Check which auth method is active
gh auth status

# Expected output with a fine-grained PAT:
#   github.com
#     ✓ Logged in to github.com account <user> (GH_TOKEN)
#     ...
#     Token scopes: (none)   ← fine-grained PATs show no classic scopes

# Test repository access
gh repo view <owner>/<repo> --json name

# Test issue access
gh issue list --repo <owner>/<repo> --limit 1

# Test PR access
gh pr list --repo <owner>/<repo> --limit 1
```

If `gh auth status` shows the default credential instead of `GH_TOKEN`, verify the variable is exported in the same shell session.

## Headless and SSH-only daemon operation (#4005)

`loom-daemon`'s own forge calls (claim reconciliation, the main-health gate,
metrics collection, the work finder, …) all shell out to `gh`, which resolves
credentials the same way an interactive shell does: `GH_TOKEN` env var →
`GITHUB_TOKEN` env var → `gh`'s own credential store (the macOS login
**keychain**, or `~/.config/gh/hosts.yml` on Linux). The keychain only unlocks
for processes running in the user's **GUI login session** — a daemon started
over SSH with a clean environment, or from a headless server with no
interactive login, cannot unlock it. Without an env-var token, every `gh` call
the daemon makes will `401`.

**The fix is an exported token, not a new credential store.** Loom does not
provision a separate daemon-managed PAT file — `export GH_TOKEN` (or
`GITHUB_TOKEN`) before starting the daemon, and the existing forwarding
mechanism carries it the rest of the way:

```bash
# On the headless / SSH-only host, before starting the daemon:
export GH_TOKEN=github_pat_xxxxxxxxxxxxxxxxxxxx
./.loom/scripts/cli/loom-daemon-start.sh
```

`loom-daemon-start.sh` forwards any exported `GH_TOKEN` / `GITHUB_TOKEN` /
`GITEA_TOKEN` / `FORGE_TOKEN` into the launchd plist's `EnvironmentVariables`
(macOS) or the backgrounded process's inherited environment (`--no-launchd` /
Linux) — so the daemon **and every sweep child it dispatches** see the token,
with no per-sweep configuration needed. The daemon inherits its environment
**from the shell that started it** — export the token *before* invoking
`loom-daemon-start.sh`, not after. A later `loom-daemon-update.sh` restart
re-renders the plist from the *current* shell's environment, so an
already-running daemon does not silently lose a token that was exported only
in a now-closed session (the same footgun `LOOM_WORK_FINDER` / autonomy-flag
env replay has — see [`daemon-reference.md`](daemon-reference.md)).

**Startup credential preflight.** The daemon resolves its forge credential
once at boot, immediately before its first `gh` consumer (the claim
reconciliation startup pass), and reports the outcome — `info!` naming which
mechanism won (`GH_TOKEN`, `GITHUB_TOKEN`, or `gh`'s own credential store) plus
a non-secret fingerprint (never the token itself), or `error!` naming both
remedies (export a token, or unlock the login keychain from a GUI session)
when nothing resolves. This turns the pre-#4005 failure mode — a daemon that
boots clean and then 401s silently on every forge call for the life of the
process — into a single loud, actionable line. The result is also visible
without reading logs via `loom-daemon status` ("Forge credential: OK/DEGRADED
— …"); see [`daemon-reference.md`](daemon-reference.md) for the field shape.
The preflight is read-only, bounded (never blocks daemon startup), and never
logs, prints, or serializes a token value.

**GitHub only.** The preflight covers `GH_TOKEN`/`GITHUB_TOKEN` because the
daemon's own forge calls are exclusively `gh`-CLI-based. `GITEA_TOKEN` /
`FORGE_TOKEN` forwarding still happens (for dispatched sweep children targeting
a Gitea-backed repo — see [`forge-authentication.md`](forge-authentication.md))
but the daemon process itself never calls a Gitea API, so there is nothing to
preflight for it.

**Plist permissions.** Because the rendered launchd plist embeds the token
value verbatim in `EnvironmentVariables`, `loom-daemon-start.sh` hardens the
file to mode `0600` whenever it carries a `GH_TOKEN`/`GITEA_TOKEN`/
`FORGE_TOKEN`, so a local user other than the daemon's owner cannot read the
PAT out of `~/Library/LaunchAgents`.

**Starting the daemon headlessly over SSH (#4130 — resolved).** Earlier this
section noted that `launchctl bootstrap gui/$UID` (the domain
`loom-daemon-start.sh` originally hardcoded on macOS) fails over SSH with
`error 125: Domain does not support specified action`, because `gui/$UID` is a
per-GUI-login domain that does not exist in an SSH session — so a not-yet-running
daemon could not be *started* remotely on macOS. That gap is now closed: the
shared resolver `resolve_launchd_domain()` prefers `gui/<uid>` when a GUI login
is active and otherwise falls back to the background per-user `user/<uid>` domain
that `sshd` instantiates (running as the user, not root). So a headless / SSH-only
`loom-daemon-start.sh` now completes, and stop/update find the resulting job. Pin
the domain with `LOOM_LAUNCHD_DOMAIN` if needed; the rejected alternatives
(a root system `LaunchDaemon`, `launchctl asuser`) and the login-keychain / TCC
consequences of the non-Aqua domain are covered in
[`daemon-reference.md` → "launchd domain resolution (#4130)"](daemon-reference.md).
As before, export a `GH_TOKEN` for forge auth in a headless session (the login
keychain may be locked) — the #4005 credential preflight reports this loudly.

## Troubleshooting

### Token not being picked up

- Confirm `echo $GH_TOKEN` shows the token value
- The variable must be **exported**, not just set: `export GH_TOKEN=...`
- If using Daemon Mode, restart the daemon after setting the variable

### Permission errors (403 / insufficient scope)

- Verify the PAT is scoped to the correct repository
- Check that all required permissions are granted (see table above)
- Fine-grained PATs do not show classic scopes in `gh auth status` — this is expected

### Token expired

- Fine-grained PATs have an expiration date set at creation
- Generate a new token and update the `GH_TOKEN` value
- Consider setting a calendar reminder before expiration

## Security Notes

- **Never commit tokens** to the repository. Add `.env` to `.gitignore` if using an env file.
- Fine-grained PATs are more secure than classic tokens because they limit both repository and permission scope.
- Use the minimum permissions required. The table above lists exactly what Loom needs.
- Rotate tokens periodically — 90-day expiration is a reasonable default.
