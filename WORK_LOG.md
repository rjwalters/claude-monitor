# Work Log

Chronological record of merged PRs and closed issues, newest first. Maintained automatically by the Guide role.

### 2026-08-15

- **PR #86**: refactor: unify percent-severity color thresholds into shared PercentSeverity enum
- **Issue #85** (closed): Remove duplicated percent-severity color logic (colorForPercent x2 + inline copy in main.swift)
- **PR #82**: refactor: convert static-only window controllers to enums
- **Issue #81** (closed): Convert static-only window-controller classes to enums for consistency
- **Issue #79** (closed): Remove unused formatResetTime function in UsagePopoverView.swift
- **PR #78**: refactor: remove dead helpers and struct with zero call sites
- **Issue #76** (closed): Remove dead code: unused helpers/struct in UsageStore, UsageChartView, UsagePopoverView

### 2026-08-06

- **PR #72**: ci: add workflow_dispatch fallback trigger, document manual CI re-run
- **Issue #66** (closed): GitHub Actions not triggering on open PRs (#64, #65)
- **PR #70**: feat: round-trip OpenAI/Codex credentials through clipboard account transfer
- **Issue #67** (closed): Extend clipboard account transfer format to round-trip OpenAI/Codex credentials
- **PR #64**: fix: report accurate exported-account count when copying accounts
- **Issue #63** (closed): Copy/Paste Accounts silently drops OpenAI/Codex accounts; copy count over-reports

### 2026-08-05

- **Issue #60** (closed): Guide: document-maintenance phase creates a self-perpetuating docs-PR loop
- **PR #61**: fix(guide): exclude self-authored docs-maintenance PRs from work-log scan
- **PR #58**: docs: Guide document maintenance update
- **PR #57**: docs: Guide document maintenance update
- **PR #56**: docs: Guide document maintenance update

### 2026-08-04

- **PR #54**: Order capped accounts by time until they are usable again

### 2026-08-02

- **Issue #51** (closed): Adopt Swift 6 language mode package-wide (3 known concurrency errors to fix)
- **PR #53**: build: adopt Swift 6 language mode package-wide
- **Issue #52** (closed): CI: bump actions/checkout to v5 (Node.js 20 deprecation warning)

### 2026-07-31

- **Issue #45** (closed): Healing migration: merge duplicate provider accounts sharing an email
- **PR #50**: fix: heal duplicate provider accounts sharing an email at launch
- **Issue #47** (closed): Provider-aware column titles in the summary table ("Fable Left" is meaningless for OpenAI rows)
- **PR #49**: fix: provider-aware column titles for premium/extra summary columns
- **Issue #46** (closed): macOS: `--version` without `--headless` launches the GUI instead of printing
- **PR #48**: macOS: dispatch --version at top level so it never launches the GUI
- **Issue #38** (closed): Verify the OpenAI token-refresh path against a real expiring token
- **Issue #39** (closed): build-macos-app.sh User-Agent detection misses a Homebrew-installed claude
- **PR #44**: fix: fall back to claude --version for User-Agent detection
- **Issue #40** (closed): sortedAccountsForPopover tie-breaks on account UUID, giving arbitrary order
- **PR #43**: fix: tiebreak account ordering on natural display name, not account id
- **Issue #41** (closed): Document that a clean local swift build does not gate Swift strict-concurrency errors
- **PR #42**: docs: clarify local swift build does not gate strict-concurrency errors

### 2026-07-30

- **PR #37**: fix: grow the mascot to 16x13 to balance against the rosette
- **PR #36**: feat: use OpenAI's rosette for the provider badge
- **PR #35**: feat: draw provider badges as pixel-art glyphs
- **PR #34**: fix: sort account names naturally (agent-10 after agent-9)
- **Issue #32** (closed): Chart OpenAI per-model sub-limits (additional_rate_limits[]) in the per-account history window
- **PR #33**: feat: persist and chart OpenAI per-model sub-limits (named_limits)
- **Issue #25** (closed): Epic: multi-provider support — monitor OpenAI GPT (Codex) subscription accounts alongside Claude
- **Issue #29** (closed): [Epic #25 Phase 3] OpenAI usage poller + provider-aware ranking export
- **PR #31**: feat: poll OpenAI/Codex usage and tag ranking.json with provider
- **Issue #28** (closed): [Epic #25 Phase 2] Provider abstraction: Account schema + provider-agnostic rate-limit model
- **PR #30**: feat: provider-agnostic rate-limit model + provider column on accounts
- **Issue #26** (closed): spike: can a cheap authenticated probe read ChatGPT/Codex subscription usage + rate-limit windows?
- **PR #27**: docs: write up static-analysis findings on ChatGPT/Codex usage probe
- **Issue #13** (closed): CI: add a Linux build job to cover the headless target
- **PR #24**: ci: add Linux build job for the headless daemon target
- **Issue #16** (closed): feature: headless CLI to export/import account records + credentials for multi-host sync
- **PR #22**: feat: headless CLI to export/import accounts + credentials for multi-host sync
- **Issue #15** (closed): accounts can persist with email=NULL (address only in account_name) — breaks downstream consumers keying on email
- **PR #23**: fix: backfill accounts.email from a well-formed account_name label
- **Issue #18** (closed): wire package.json check scripts to swift build so Loom's build gate isn't vacuous
- **PR #21**: build: wire package.json check scripts to swift build
- **Issue #19** (closed): icon-master.source.json sha256 no longer matches icon-master.png
- **PR #20**: fix: update icon-master.source.json sha256 to match tracked PNG
- **Issue #14** (closed): claude-monitor.service: network-online.target ordering is a no-op in the systemd user manager
- **PR #17**: fix: drop no-op network-online ordering from user systemd unit

### 2026-07-28

- **Issue #7** (closed): Refresh README screenshots — they predate the 1.15 UI
- **PR #12**: docs: refresh README screenshots to the 1.15 UI
- **Issue #6** (closed): Document Roll Token workflow (temporary fix) and its reliance on undocumented claude.ai endpoints
- **PR #11**: docs: document Roll Token workflow and its undocumented-endpoint dependency
- **Issue #5** (closed): dist/cli.js fails at startup: Cannot find package 'commander' (ERR_MODULE_NOT_FOUND)
- **PR #10**: docs: note legacy pre-2.0 artifact cleanup in Uninstall (closes stale-CLI report)
- **Issue #8** (closed): Headless Linux mode: run the usage poller as a daemon on cloud loom worker hosts
- **PR #9**: Add headless Linux mode: portable core + UI-less poll loop daemon

### 2026-07-22

- **PR #4**: Add Fable/premium usage tracking and master account list
- **Issue #2** (closed): Emit ranking.json for external load balancers (loom + lean-genius)
- **PR #3**: Emit ranking.json for external load balancers (loom + lean-genius)

### 2025-12-15

- **PR #1**: Release v1.5.0: Fix extension resource cleanup
