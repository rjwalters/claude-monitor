// Content script that runs on claude.ai/settings/usage
// Use browser API for Firefox, chrome for Chrome
const browserAPI = typeof browser !== 'undefined' ? browser : chrome;

function extractUsageData() {
  const text = document.body.innerText;

  // Skip if it's a Cloudflare page
  if (text.includes("Verify you are human") || text.includes("Cloudflare")) {
    return null;
  }

  // Try to detect account/email from page
  let accountId = 'default';
  let email = '';

  // Look for email in the page (usually in settings/profile area)
  const emailMatch = text.match(/([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/);
  if (emailMatch) {
    email = emailMatch[1];
    accountId = email.split('@')[0]; // Use username part as account ID
  }

  // Extract all usage sections
  const sections = [];

  // Parse "All models" section
  const allModelsMatch = text.match(/All models\s*Resets?\s+([^\n]+)\s*(\d+)%\s*used/i);
  if (allModelsMatch) {
    sections.push({
      type: 'all_models',
      resetTime: allModelsMatch[1].trim(),
      percentUsed: parseInt(allModelsMatch[2], 10)
    });
  }

  // Parse "Sonnet only" section
  const sonnetMatch = text.match(/Sonnet only\s*Resets?\s+([^\n]+)\s*(\d+)%\s*used/i);
  if (sonnetMatch) {
    sections.push({
      type: 'sonnet_only',
      resetTime: sonnetMatch[1].trim(),
      percentUsed: parseInt(sonnetMatch[2], 10)
    });
  }

  // Extract primary percentage (first one found)
  const percentMatches = text.match(/(\d+(?:\.\d+)?)\s*%\s*used/g) || [];
  const percentages = percentMatches.map(m => parseFloat(m.match(/(\d+(?:\.\d+)?)/)[1]));

  // Extract reset info
  const resetMatch = text.match(/Resets?\s+(?:in\s+)?(\d+\s*(?:min|hour|day|Mon|Tue|Wed|Thu|Fri|Sat|Sun)[^\n]*)/i);
  const resetInfo = resetMatch ? resetMatch[1].trim() : '';

  // Get weekly reset time
  const weeklyResetMatch = text.match(/Weekly limits[\s\S]*?Resets?\s+([^\n]+)/i);
  const weeklyReset = weeklyResetMatch ? weeklyResetMatch[1].trim() : '';

  const data = {
    timestamp: new Date().toISOString(),
    accountId,
    email,
    url: window.location.href,
    percentages,
    primaryPercent: percentages[0] || 0,
    resetInfo,
    weeklyReset,
    sections,
    rawText: text.slice(0, 8000)
  };

  return data;
}

// Store data with history
async function storeUsageData(data) {
  if (!data) return;

  try {
    // Get existing data for this account
    const storageKey = `account_${data.accountId}`;
    const result = await browserAPI.storage.local.get([storageKey, 'accounts']);

    const accountData = result[storageKey] || { history: [] };
    const accounts = result.accounts || [];

    // Add to history (keep last 1000 entries per account)
    accountData.history.unshift({
      timestamp: data.timestamp,
      primaryPercent: data.primaryPercent,
      percentages: data.percentages,
      resetInfo: data.resetInfo,
      sections: data.sections
    });

    if (accountData.history.length > 1000) {
      accountData.history = accountData.history.slice(0, 1000);
    }

    // Update latest
    accountData.latest = data;
    accountData.email = data.email;
    accountData.lastUpdated = data.timestamp;

    // Track known accounts
    if (!accounts.includes(data.accountId)) {
      accounts.push(data.accountId);
    }

    // Save
    await browserAPI.storage.local.set({
      [storageKey]: accountData,
      accounts,
      lastUpdate: data
    });

    console.log(`[Claude Monitor] Saved data for ${data.accountId}: ${data.primaryPercent}%`);

    // Notify background script
    browserAPI.runtime.sendMessage({
      type: 'USAGE_UPDATE',
      accountId: data.accountId,
      data
    });

  } catch (err) {
    console.error('[Claude Monitor] Error storing data:', err);
  }
}

// Main function
function captureUsage() {
  const data = extractUsageData();
  if (data) {
    storeUsageData(data);
  }
}

// Run on page load and periodically
if (document.readyState === 'complete') {
  captureUsage();
} else {
  window.addEventListener('load', captureUsage);
}

// Re-capture after dynamic content loads
setTimeout(captureUsage, 3000);
setTimeout(captureUsage, 10000);

// Also capture on visibility change (when tab becomes active)
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    setTimeout(captureUsage, 1000);
  }
});
