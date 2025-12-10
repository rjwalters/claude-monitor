// Content script that runs on claude.ai/settings/usage
// Use browser API for Firefox, chrome for Chrome
const browserAPI = typeof browser !== 'undefined' ? browser : chrome;

function extractUsageData() {
  const text = document.body.innerText;

  // Skip if it's a Cloudflare page or error page
  if (text.includes("Verify you are human") || text.includes("Cloudflare") ||
      text.includes("Something went wrong") || text.length < 100) {
    console.log('[Claude Monitor] Page not ready or blocked');
    return null;
  }

  // Helper to get cookie value by name
  function getCookieValue(name) {
    const match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
    return match ? decodeURIComponent(match[2]) : null;
  }

  // Try to detect account info
  let accountId = 'default';
  let accountName = '';
  let email = '';
  let plan = '';

  // PRIMARY: Use lastActiveOrg cookie as the unique account ID
  const lastActiveOrg = getCookieValue('lastActiveOrg');
  if (lastActiveOrg) {
    accountId = lastActiveOrg;
  }

  // Look for email in the page text
  const emailMatch = text.match(/([a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,})/);
  if (emailMatch) {
    email = emailMatch[1];
    // Only use email as accountId if we don't have lastActiveOrg
    if (accountId === 'default') {
      accountId = email.split('@')[0];
    }
  }

  // Look for plan name (Max, Pro, Team, etc.)
  const planMatch = text.match(/(Max|Pro|Team|Enterprise|Free)\s*plan/i);
  if (planMatch) {
    plan = planMatch[1] + ' plan';
  }

  // Try to extract account name - look for full name before plan type
  // Pattern: "FirstName LastName\nMax plan" (skip initials like "RW")
  // This becomes the default display name (user can edit later)
  const nameBeforePlanMatch = text.match(/([A-Z][a-z]+(?:\s+[A-Z][a-z]+)+)\n(?:Max|Pro|Team|Enterprise|Free)\s*plan/);
  if (nameBeforePlanMatch) {
    accountName = nameBeforePlanMatch[1].trim();
    // Only use name as accountId if we don't have lastActiveOrg or email
    if (accountId === 'default' && accountName) {
      accountId = accountName.toLowerCase().replace(/\s+/g, '_');
    }
  }

  // Initialize usage data structure
  const usage = {
    session: { percent: null, reset: null },
    weeklyAll: { percent: null, reset: null },
    weeklySonnet: { percent: null, reset: null }
  };

  // Strategy 1: Parse structured blocks using multiple patterns
  // Look for "Current session" block
  const sessionMatch = text.match(/Current\s+session[\s\S]*?(\d+)\s*%\s*used/i);
  if (sessionMatch) {
    usage.session.percent = parseInt(sessionMatch[1], 10);
  }

  // Look for session reset time
  const sessionResetMatch = text.match(/Current\s+session[\s\S]*?Resets?\s+(?:in\s+)?([^\n]+?)(?:\n|\d+\s*%)/i);
  if (sessionResetMatch) {
    usage.session.reset = sessionResetMatch[1].trim();
  }

  // Look for "All models" block
  const allModelsMatch = text.match(/All\s+models[\s\S]*?(\d+)\s*%\s*used/i);
  if (allModelsMatch) {
    usage.weeklyAll.percent = parseInt(allModelsMatch[1], 10);
  }

  // Look for All models reset time
  const allModelsResetMatch = text.match(/All\s+models[\s\S]*?Resets?\s+([^\n]+?)(?:\n|\d+\s*%)/i);
  if (allModelsResetMatch) {
    usage.weeklyAll.reset = allModelsResetMatch[1].trim();
  }

  // Look for "Sonnet" block (could be "Sonnet only" or just "Sonnet")
  const sonnetMatch = text.match(/Sonnet(?:\s+only)?[\s\S]*?(\d+)\s*%\s*used/i);
  if (sonnetMatch) {
    usage.weeklySonnet.percent = parseInt(sonnetMatch[1], 10);
  }

  // Look for Sonnet reset time
  const sonnetResetMatch = text.match(/Sonnet(?:\s+only)?[\s\S]*?Resets?\s+([^\n]+?)(?:\n|\d+\s*%)/i);
  if (sonnetResetMatch) {
    usage.weeklySonnet.reset = sonnetResetMatch[1].trim();
  }

  // Strategy 2: Fallback - find all "X% used" patterns with context
  if (usage.session.percent === null) {
    const allPercentMatches = [...text.matchAll(/(\d+)\s*%\s*used/gi)];
    if (allPercentMatches.length > 0) {
      usage.session.percent = parseInt(allPercentMatches[0][1], 10);
    }
    if (allPercentMatches.length > 1 && usage.weeklyAll.percent === null) {
      usage.weeklyAll.percent = parseInt(allPercentMatches[1][1], 10);
    }
    if (allPercentMatches.length > 2 && usage.weeklySonnet.percent === null) {
      usage.weeklySonnet.percent = parseInt(allPercentMatches[2][1], 10);
    }
  }

  // Strategy 3: Find reset times by pattern
  const resetTimes = [...text.matchAll(/Resets?\s+(?:in\s+)?([^\n]+)/gi)];
  if (resetTimes.length > 0 && !usage.session.reset) {
    usage.session.reset = resetTimes[0][1].trim();
  }
  if (resetTimes.length > 1 && !usage.weeklyAll.reset) {
    usage.weeklyAll.reset = resetTimes[1][1].trim();
  }

  // Determine primary percent (highest priority: session, then weekly all)
  const primaryPercent = usage.session.percent ?? usage.weeklyAll.percent ?? 0;

  // Build sections array for backward compatibility
  const sections = [];
  if (usage.session.percent !== null) {
    sections.push({
      type: 'session',
      percentUsed: usage.session.percent,
      resetTime: usage.session.reset
    });
  }
  if (usage.weeklyAll.percent !== null) {
    sections.push({
      type: 'all_models',
      percentUsed: usage.weeklyAll.percent,
      resetTime: usage.weeklyAll.reset
    });
  }
  if (usage.weeklySonnet.percent !== null) {
    sections.push({
      type: 'sonnet_only',
      percentUsed: usage.weeklySonnet.percent,
      resetTime: usage.weeklySonnet.reset
    });
  }

  const data = {
    timestamp: new Date().toISOString(),
    accountId,
    accountName,
    email,
    plan,
    url: window.location.href,

    // Structured usage data
    usage,

    // Flattened for easy access
    sessionPercent: usage.session.percent,
    sessionReset: usage.session.reset,
    weeklyAllPercent: usage.weeklyAll.percent,
    weeklyReset: usage.weeklyAll.reset,
    weeklySonnetPercent: usage.weeklySonnet.percent,

    // Legacy fields
    primaryPercent,
    percentages: [usage.session.percent, usage.weeklyAll.percent, usage.weeklySonnet.percent].filter(p => p !== null),
    sections,

    // Raw text for debugging (truncated)
    rawText: text.slice(0, 2000)
  };

  console.log('[Claude Monitor] Extracted:', {
    session: usage.session,
    weeklyAll: usage.weeklyAll,
    weeklySonnet: usage.weeklySonnet
  });

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
      usage: data.usage,
      primaryPercent: data.primaryPercent
    });

    if (accountData.history.length > 1000) {
      accountData.history = accountData.history.slice(0, 1000);
    }

    // Update latest
    accountData.latest = data;
    accountData.accountName = data.accountName;
    accountData.email = data.email;
    accountData.plan = data.plan;
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

    console.log(`[Claude Monitor] Saved: session=${data.sessionPercent}%, weekly=${data.weeklyAllPercent}%, sonnet=${data.weeklySonnetPercent}%`);

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
  // Store if we have any valid percentage data (session, weekly, or sonnet)
  const hasValidData = data && (
    data.sessionPercent !== null ||
    data.weeklyAllPercent !== null ||
    data.weeklySonnetPercent !== null
  );
  if (hasValidData) {
    storeUsageData(data);
  }
}

// Run on page load and periodically
if (document.readyState === 'complete') {
  setTimeout(captureUsage, 500);
} else {
  window.addEventListener('load', () => setTimeout(captureUsage, 500));
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
