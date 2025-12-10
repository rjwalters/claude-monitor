// Background script for Claude Usage Monitor (Chrome MV3)
// Use chrome API directly in Chrome
const browserAPI = chrome;

const NATIVE_HOST = 'claude_monitor';

// Send data to native host for persistent storage
async function sendToNativeHost(data) {
  try {
    const response = await browserAPI.runtime.sendNativeMessage(NATIVE_HOST, data);
    console.log('[Claude Monitor] Native host response:', response);
    return response;
  } catch (err) {
    console.warn('[Claude Monitor] Native messaging not available:', err.message);
    // Fall back to extension storage only
    return null;
  }
}

// Listen for messages from content script
browserAPI.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'USAGE_UPDATE') {
    console.log('[Claude Monitor] Received usage update for:', message.accountId);

    // Send to native host for file storage
    sendToNativeHost({
      type: 'USAGE_UPDATE',
      accountId: message.accountId,
      data: message.data
    });

    // Update badge (MV3 uses 'action' instead of 'browserAction')
    if (message.data && message.data.primaryPercent !== undefined) {
      const percent = Math.round(message.data.primaryPercent);
      browserAPI.action.setBadgeText({ text: `${percent}%` });

      // Color based on usage
      let color = '#10b981'; // green
      if (percent >= 80) color = '#ef4444'; // red
      else if (percent >= 60) color = '#f59e0b'; // yellow

      browserAPI.action.setBadgeBackgroundColor({ color });
    }
  }
});

// Set up periodic refresh alarm (every 5 minutes)
browserAPI.alarms.create('refreshUsage', {
  periodInMinutes: 5
});

browserAPI.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'refreshUsage') {
    // Find and refresh any open usage tabs
    browserAPI.tabs.query({ url: '*://claude.ai/settings/usage*' }, (tabs) => {
      if (tabs && tabs.length > 0) {
        tabs.forEach((tab) => {
          browserAPI.tabs.reload(tab.id);
        });
        console.log('[Claude Monitor] Refreshed', tabs.length, 'usage tab(s)');
      }
    });
  }
});

// Initialize on install (MV3 uses 'action' instead of 'browserAction')
browserAPI.runtime.onInstalled.addListener(() => {
  console.log('[Claude Monitor] Extension installed');
  browserAPI.action.setBadgeText({ text: '?' });
  browserAPI.action.setBadgeBackgroundColor({ color: '#6b7280' });
});
