# Claude Usage Monitor Extension

Firefox/Chrome extension to monitor Claude AI usage without triggering Cloudflare bot detection.

## Installation

### Firefox

1. Open Firefox and go to `about:debugging`
2. Click "This Firefox" in the sidebar
3. Click "Load Temporary Add-on"
4. Navigate to this `extension` folder and select `manifest.json`

### Chrome

1. Open Chrome and go to `chrome://extensions`
2. Enable "Developer mode" (toggle in top right)
3. Click "Load unpacked"
4. Select this `extension` folder

## Usage

1. After installing, click the extension icon in your browser toolbar
2. Click "Open Usage Page" to visit claude.ai/settings/usage
3. Log in if needed - the extension will capture usage data automatically
4. The extension refreshes data every 5 minutes when the usage page is open
5. Click "Export Data (JSON)" to save usage history

## How It Works

- Uses a content script to extract data from the Claude usage page
- Runs in your actual browser with your real session - no automation detection
- Stores usage history in browser local storage
- Can export data to JSON for the CLI tool to read

## For Multiple Accounts

For multiple accounts, you can:
1. Use Firefox Container Tabs (with Multi-Account Containers extension)
2. Use separate browser profiles
3. Install this extension in each container/profile
