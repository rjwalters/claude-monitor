# Spikes

Time-boxed investigation write-ups. A spike answers one question — "is this
feasible", "what does this endpoint actually return" — and its value is the
evidence, not the code.

Conventions:

- **Name files `YYYY-MM-DD-topic.md`.** A spike is a snapshot of what was true
  on a date, not living documentation.
- **State clearly what was verified versus assumed.** These documents get read
  later as if they were contracts, so an unverified hypothesis has to be
  labelled as one.
- **When a later run supersedes an earlier finding, mark the superseding
  section as authoritative in place** rather than deleting the original. The
  wrong first answer and the reason it was wrong are usually the most useful
  part.

## Index

| Spike | Question | Outcome |
|-------|----------|---------|
| [2026-07-30-codex-usage-probe.md](2026-07-30-codex-usage-probe.md) | Can a cheap authenticated probe read ChatGPT/Codex subscription usage and rate-limit windows? | **Yes.** `GET chatgpt.com/backend-api/wham/usage` with the Codex bearer token. |

### Reading the Codex probe write-up

That document has two layers, and only the second is binding. It opens with
static analysis of the Codex CLI binary, which produced a plausible but
**wrong** guess at the wire format. The later "Live verification
(AUTHORITATIVE)" section records what a real request returned and corrects it —
different field names, a different route, and the discovery that a session
window may legitimately be absent.

Design against the live-verification section. `OpenAIAPI.swift` and
`RateLimitWindow.swift` both cite it.

`codex-usage-probe.sh` beside it is runnable: it prints only status codes and
redacted field names, never token values.
