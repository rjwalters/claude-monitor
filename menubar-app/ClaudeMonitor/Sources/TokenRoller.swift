import AppKit
import Foundation

/// Builds the browser-console script that revokes every Claude Code authorization
/// token for one account.
///
/// Why a copy-paste console script instead of an in-app HTTP call: revoking a
/// long-lived `sk-ant-oat01` token hits `claude.ai/api/oauth/organizations/{org}/
/// oauth_tokens/{id}/revoke`, which authenticates with the **claude.ai web
/// session cookie** — not the Bearer token itself (that returns
/// `account_session_invalid`). So the revoke can only run from a page already
/// logged into claude.ai as the target account. The app bakes the org id into the
/// script and hands it to the user to paste.
///
/// These endpoints are undocumented internal claude.ai APIs with no public,
/// supported alternative today. They may change without notice — if a roll stops
/// working, the script template here is the thing to update.
enum TokenRoller {
    static let settingsURL = URL(string: "https://claude.ai/settings/claude-code")!

    /// The `revoke-all` console script for a given org, ready to paste. Lists the
    /// account's live tokens, then revokes each one, re-listing between rounds so
    /// stragglers (Anthropic's revoke is known to be flaky) get retried. The user
    /// mints a fresh token with `claude setup-token` afterward.
    static func revokeAllScript(orgId: String) -> String {
        """
        (async () => {
          const ORG = '\(orgId)';
          const base = `/api/oauth/organizations/${ORG}/oauth_tokens`;
          const H = { 'content-type': 'application/json',
                      'anthropic-client-platform': 'web_claude_ai',
                      'anthropic-client-version': '1.0.0' };
          const sleep = ms => new Promise(r => setTimeout(r, ms));
          const live = async () => {
            const r = await fetch(base, { credentials: 'include', headers: H });
            if (r.status === 403) { console.error('Wrong account — this browser is not logged into org ' + ORG); return null; }
            if (!r.ok) { console.error('List failed', r.status); return null; }
            return (await r.json()).filter(t => !t.is_revoked).map(t => t.id);
          };
          let pending = await live();
          if (pending === null) return;
          console.log(`Revoking ${pending.length} token(s) for ${ORG}...`);
          let round = 0, total = 0;
          while (pending.length && round < 10) {
            round++;
            for (const id of pending) {
              try {
                const r = await fetch(`${base}/${id}/revoke`, { method: 'POST', credentials: 'include', headers: H, body: JSON.stringify(id) });
                if (r.status === 204) total++; else console.warn('non-204', r.status, id);
              } catch (e) { console.warn('error', id, e.message); }
              await sleep(120);
            }
            await sleep(500);
            pending = await live();
            if (pending === null) break;
          }
          console.log(`Done — revoked ${total}. Remaining live: ${pending ? pending.length : '?'}. Reload the page to confirm, then run: claude setup-token`);
        })();
        """
    }

    /// Put the script on the pasteboard.
    static func copyScript(orgId: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(revokeAllScript(orgId: orgId), forType: .string)
    }

    /// Copy the `claude setup-token` command for the mint step.
    static func copySetupTokenCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("claude setup-token", forType: .string)
    }
}
