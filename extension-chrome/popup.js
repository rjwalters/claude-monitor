// Popup script for Claude Usage Monitor
// Use browser API for Firefox, chrome for Chrome
const browserAPI = typeof browser !== 'undefined' ? browser : chrome;
const NATIVE_HOST = 'claude_monitor';

function getUsageClass(percent) {
  if (percent >= 80) return 'high';
  if (percent >= 60) return 'medium';
  return 'low';
}

function formatTime(isoString) {
  if (!isoString) return 'never';
  const date = new Date(isoString);
  const now = new Date();
  const diffMs = now - date;
  const diffMins = Math.floor(diffMs / 60000);

  if (diffMins < 1) return 'just now';
  if (diffMins < 60) return `${diffMins} min ago`;
  if (diffMins < 1440) return `${Math.floor(diffMins / 60)} hours ago`;
  return date.toLocaleDateString();
}

function renderAccountCard(accountId, accountData) {
  const latest = accountData.latest || {};
  const percent = latest.primaryPercent || 0;
  const usageClass = getUsageClass(percent);

  // Display name: email or accountId
  const displayName = accountData.email || accountId;

  // Get sections for more detail
  const sections = latest.sections || [];
  const allModels = sections.find(s => s.type === 'all_models');
  const sonnetOnly = sections.find(s => s.type === 'sonnet_only');

  let resetText = latest.resetInfo || '';
  if (allModels) {
    resetText = `Resets ${allModels.resetTime}`;
  }

  return `
    <div class="account-card">
      <div class="account-header">
        <span class="account-name">${escapeHtml(displayName)}</span>
        <span class="account-percent percent-${usageClass}">${percent}%</span>
      </div>
      <div class="usage-bar">
        <div class="usage-fill fill-${usageClass}" style="width: ${Math.min(percent, 100)}%"></div>
      </div>
      <div class="reset-info">${escapeHtml(resetText)}</div>
      <div class="timestamp">Updated: ${formatTime(accountData.lastUpdated)}</div>
    </div>
  `;
}

function escapeHtml(str) {
  if (!str) return '';
  return str.replace(/[&<>"']/g, (m) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
  }[m]));
}

async function loadData() {
  const content = document.getElementById('content');
  const countBadge = document.getElementById('accountCount');

  try {
    // Get accounts list and their data from extension storage
    const result = await browserAPI.storage.local.get(null);
    const accounts = result.accounts || [];

    if (accounts.length === 0) {
      content.innerHTML = '<div class="no-data">No usage data yet.<br>Visit claude.ai/settings/usage to collect data.</div>';
      countBadge.textContent = '0 accounts';
      return;
    }

    countBadge.textContent = `${accounts.length} account${accounts.length !== 1 ? 's' : ''}`;

    // Render each account
    let html = '';
    for (const accountId of accounts) {
      const accountData = result[`account_${accountId}`];
      if (accountData) {
        html += renderAccountCard(accountId, accountData);
      }
    }

    content.innerHTML = html || '<div class="no-data">No usage data yet.</div>';

  } catch (err) {
    console.error('[Claude Monitor] Error loading data:', err);
    content.innerHTML = `<div class="no-data">Error loading data: ${err.message}</div>`;
  }
}

// Check native host connection
async function checkNativeHost() {
  const statusEl = document.getElementById('status');
  try {
    const response = await browserAPI.runtime.sendNativeMessage(NATIVE_HOST, { type: 'GET_DATA' });
    if (response && response.success) {
      statusEl.textContent = 'Connected to native host ✓';
      statusEl.className = 'status connected';
      return response.data;
    } else {
      statusEl.textContent = 'Native host error';
      statusEl.className = 'status';
    }
  } catch (err) {
    statusEl.textContent = 'Native host not connected';
    statusEl.className = 'status';
    console.log('[Claude Monitor] Native host not available:', err.message);
  }
  return null;
}

// Open usage page button
document.getElementById('openUsage').addEventListener('click', () => {
  browserAPI.tabs.create({ url: 'https://claude.ai/settings/usage' });
});

// Refresh button
document.getElementById('refresh').addEventListener('click', async () => {
  const btn = document.getElementById('refresh');
  btn.textContent = '...';
  btn.disabled = true;

  // Reload any open usage tabs
  const tabs = await browserAPI.tabs.query({ url: '*://claude.ai/settings/usage*' });
  if (tabs && tabs.length > 0) {
    for (const tab of tabs) {
      await browserAPI.tabs.reload(tab.id);
    }
  }

  // Reload popup data after a short delay
  setTimeout(async () => {
    await loadData();
    btn.textContent = 'Refresh';
    btn.disabled = false;
  }, 2000);
});

// Initial load
loadData();
checkNativeHost();

// Listen for storage updates
browserAPI.storage.onChanged.addListener((changes, namespace) => {
  if (namespace === 'local') {
    loadData();
  }
});
