#!/usr/bin/env node
/**
 * Native Messaging Host for Claude Monitor
 *
 * This script receives messages from the Firefox extension
 * and writes usage data to ~/.claude-monitor/usage.db (SQLite)
 */

const fs = require('fs');
const path = require('path');
const os = require('os');

const DATA_DIR = path.join(os.homedir(), '.claude-monitor');
const DB_FILE = path.join(DATA_DIR, 'usage.db');

// Ensure data directory exists
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

// Initialize SQLite database
const Database = require('better-sqlite3');
const db = new Database(DB_FILE);

// Create tables if they don't exist
db.exec(`
  CREATE TABLE IF NOT EXISTS accounts (
    id TEXT PRIMARY KEY,
    account_name TEXT,
    email TEXT,
    plan TEXT,
    last_updated TEXT,
    sort_order INTEGER DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS usage_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    primary_percent REAL,
    session_percent REAL,
    weekly_all_percent REAL,
    weekly_sonnet_percent REAL,
    session_reset TEXT,
    weekly_reset TEXT,
    raw_data TEXT,
    FOREIGN KEY (account_id) REFERENCES accounts(id)
  );

  CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_history(account_id);
  CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_history(timestamp DESC);

  -- Token tracking from Claude Code local JSONL files
  CREATE TABLE IF NOT EXISTS token_sessions (
    session_id TEXT PRIMARY KEY,
    project_path TEXT,
    first_message_ts TEXT NOT NULL,
    last_message_ts TEXT,
    inferred_account_id TEXT,
    override_account_id TEXT,
    total_input_tokens INTEGER DEFAULT 0,
    total_output_tokens INTEGER DEFAULT 0,
    total_cache_creation_tokens INTEGER DEFAULT 0,
    total_cache_read_tokens INTEGER DEFAULT 0,
    message_count INTEGER DEFAULT 0,
    last_import_ts TEXT,
    FOREIGN KEY (inferred_account_id) REFERENCES accounts(id),
    FOREIGN KEY (override_account_id) REFERENCES accounts(id)
  );

  CREATE TABLE IF NOT EXISTS token_usage (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp TEXT NOT NULL,
    model TEXT,
    input_tokens INTEGER DEFAULT 0,
    output_tokens INTEGER DEFAULT 0,
    cache_creation_tokens INTEGER DEFAULT 0,
    cache_read_tokens INTEGER DEFAULT 0,
    message_uuid TEXT UNIQUE,
    FOREIGN KEY (session_id) REFERENCES token_sessions(session_id)
  );

  CREATE INDEX IF NOT EXISTS idx_token_usage_session ON token_usage(session_id);
  CREATE INDEX IF NOT EXISTS idx_token_usage_timestamp ON token_usage(timestamp DESC);
  CREATE INDEX IF NOT EXISTS idx_token_sessions_account ON token_sessions(inferred_account_id);

  -- Calibration data: correlates tokens with quota percentages at reset points
  CREATE TABLE IF NOT EXISTS quota_calibration (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    account_id TEXT NOT NULL,
    reset_timestamp TEXT NOT NULL,
    tokens_in_period INTEGER,
    percent_at_reset REAL,
    tokens_per_percent REAL,
    FOREIGN KEY (account_id) REFERENCES accounts(id)
  );

  CREATE INDEX IF NOT EXISTS idx_calibration_account ON quota_calibration(account_id);
`);

// Migration: Add sort_order column if it doesn't exist
try {
  db.exec(`ALTER TABLE accounts ADD COLUMN sort_order INTEGER DEFAULT 0`);
} catch (e) {
  // Column already exists, ignore
}

// Migration: Add is_synthetic column if it doesn't exist
try {
  db.exec(`ALTER TABLE usage_history ADD COLUMN is_synthetic INTEGER DEFAULT 0`);
} catch (e) {
  // Column already exists, ignore
}

// Prepared statements
// Use INSERT ... ON CONFLICT to preserve existing account_name (user-set names are never overwritten)
const upsertAccount = db.prepare(`
  INSERT INTO accounts (id, account_name, email, plan, last_updated, sort_order)
  VALUES (?, ?, ?, ?, ?, COALESCE((SELECT MAX(sort_order) + 1 FROM accounts), 0))
  ON CONFLICT(id) DO UPDATE SET
    email = COALESCE(excluded.email, accounts.email),
    plan = COALESCE(excluded.plan, accounts.plan),
    last_updated = excluded.last_updated
`);

const insertUsage = db.prepare(`
  INSERT INTO usage_history (
    account_id, timestamp, primary_percent, session_percent,
    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

// Insert synthetic reset points (for vertical line on chart)
const insertSyntheticPoint = db.prepare(`
  INSERT INTO usage_history (
    account_id, timestamp, primary_percent, session_percent,
    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
  ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1)
`);

// Settings table operations
const upsertSetting = db.prepare(`
  INSERT INTO settings (key, value) VALUES (?, ?)
  ON CONFLICT(key) DO UPDATE SET value = excluded.value
`);

/**
 * Parse a reset time string and calculate the actual reset timestamp
 * Formats: "Thu 10:00 AM" (absolute) or "in 23 hr 57 min" (relative)
 * @param {string} resetStr - The reset time string
 * @param {string} referenceTimestamp - ISO timestamp of the reading that had this reset time
 * @param {boolean} findPrevious - If true, find the most recent PAST occurrence (for reset detection)
 * @returns {Date|null} - The calculated reset time, or null if parsing failed
 */
function parseResetTime(resetStr, referenceTimestamp, findPrevious = false) {
  if (!resetStr) return null;

  const refDate = new Date(referenceTimestamp);

  // Try relative format: "in X hr Y min" or "in X hours Y minutes"
  const relativeMatch = resetStr.match(/in\s+(\d+)\s*(?:hr|hour)s?\s*(?:(\d+)\s*min)?/i);
  if (relativeMatch) {
    const hours = parseInt(relativeMatch[1], 10);
    const minutes = relativeMatch[2] ? parseInt(relativeMatch[2], 10) : 0;
    let resetTime = new Date(refDate.getTime() + (hours * 60 + minutes) * 60 * 1000);
    // For relative times, if we need the previous occurrence, subtract a week
    if (findPrevious) {
      resetTime = new Date(resetTime.getTime() - 7 * 24 * 60 * 60 * 1000);
    }
    return resetTime;
  }

  // Try absolute format: "Thu 10:00 AM" or "Thu 10:00 PM"
  const absoluteMatch = resetStr.match(/([A-Za-z]{3})\s+(\d{1,2}):(\d{2})\s*(AM|PM)/i);
  if (absoluteMatch) {
    const dayName = absoluteMatch[1];
    let hour = parseInt(absoluteMatch[2], 10);
    const minute = parseInt(absoluteMatch[3], 10);
    const ampm = absoluteMatch[4].toUpperCase();

    // Convert to 24-hour
    if (ampm === 'PM' && hour !== 12) hour += 12;
    if (ampm === 'AM' && hour === 12) hour = 0;

    // Find the next occurrence of this day/time relative to refDate
    const dayMap = { 'Sun': 0, 'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6 };
    const targetDay = dayMap[dayName];
    if (targetDay === undefined) return null;

    // Start with refDate and find the next occurrence
    const resetTime = new Date(refDate);
    resetTime.setHours(hour, minute, 0, 0);

    // Calculate days until target day
    const currentDay = refDate.getDay();
    let daysUntil = targetDay - currentDay;
    if (daysUntil < 0) daysUntil += 7;
    if (daysUntil === 0 && resetTime <= refDate) daysUntil = 7;

    resetTime.setDate(resetTime.getDate() + daysUntil);

    // If we need the previous occurrence (for reset detection), subtract a week
    if (findPrevious) {
      resetTime.setDate(resetTime.getDate() - 7);
    }

    return resetTime;
  }

  return null;
}

const getLatestUsage = db.prepare(`
  SELECT * FROM usage_history
  WHERE account_id = ?
  ORDER BY timestamp DESC
  LIMIT 1
`);

const getAllAccounts = db.prepare(`
  SELECT a.*,
    (SELECT primary_percent FROM usage_history WHERE account_id = a.id ORDER BY timestamp DESC LIMIT 1) as latest_percent
  FROM accounts a
  ORDER BY a.sort_order ASC, a.last_updated DESC
`);

const updateAccountSortOrder = db.prepare(`
  UPDATE accounts SET sort_order = ? WHERE id = ?
`);

const getMaxSortOrder = db.prepare(`
  SELECT COALESCE(MAX(sort_order), 0) as max_sort FROM accounts
`);

const getAccountHistory = db.prepare(`
  SELECT * FROM usage_history
  WHERE account_id = ?
  ORDER BY timestamp DESC
  LIMIT ?
`);

// Token tracking prepared statements
const upsertTokenSession = db.prepare(`
  INSERT INTO token_sessions (
    session_id, project_path, first_message_ts, last_message_ts,
    inferred_account_id, total_input_tokens, total_output_tokens,
    total_cache_creation_tokens, total_cache_read_tokens, message_count, last_import_ts
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  ON CONFLICT(session_id) DO UPDATE SET
    last_message_ts = excluded.last_message_ts,
    total_input_tokens = excluded.total_input_tokens,
    total_output_tokens = excluded.total_output_tokens,
    total_cache_creation_tokens = excluded.total_cache_creation_tokens,
    total_cache_read_tokens = excluded.total_cache_read_tokens,
    message_count = excluded.message_count,
    last_import_ts = excluded.last_import_ts
`);

const insertTokenUsage = db.prepare(`
  INSERT OR IGNORE INTO token_usage (
    session_id, timestamp, model, input_tokens, output_tokens,
    cache_creation_tokens, cache_read_tokens, message_uuid
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
`);

const inferAccountForTimestamp = db.prepare(`
  SELECT account_id FROM usage_history
  WHERE timestamp <= ?
  ORDER BY timestamp DESC
  LIMIT 1
`);

const getTokenSessionsSummary = db.prepare(`
  SELECT
    ts.session_id,
    ts.project_path,
    ts.first_message_ts,
    ts.last_message_ts,
    COALESCE(ts.override_account_id, ts.inferred_account_id) as account_id,
    ts.total_input_tokens,
    ts.total_output_tokens,
    ts.total_cache_creation_tokens,
    ts.total_cache_read_tokens,
    ts.message_count
  FROM token_sessions ts
  ORDER BY ts.first_message_ts DESC
`);

const getTokenSummaryByAccount = db.prepare(`
  SELECT
    COALESCE(ts.override_account_id, ts.inferred_account_id) as account_id,
    SUM(ts.total_input_tokens) as total_input,
    SUM(ts.total_output_tokens) as total_output,
    SUM(ts.total_cache_creation_tokens) as total_cache_creation,
    SUM(ts.total_cache_read_tokens) as total_cache_read,
    SUM(ts.message_count) as total_messages,
    COUNT(*) as session_count
  FROM token_sessions ts
  WHERE ts.first_message_ts >= ?
  GROUP BY account_id
`);

const getDailyTokensByAccount = db.prepare(`
  SELECT
    date(tu.timestamp) as day,
    COALESCE(ts.override_account_id, ts.inferred_account_id) as account_id,
    SUM(tu.input_tokens) as input_tokens,
    SUM(tu.output_tokens) as output_tokens,
    SUM(tu.cache_creation_tokens) as cache_creation_tokens,
    SUM(tu.cache_read_tokens) as cache_read_tokens,
    COUNT(*) as message_count
  FROM token_usage tu
  JOIN token_sessions ts ON tu.session_id = ts.session_id
  WHERE tu.timestamp >= ?
  GROUP BY day, account_id
  ORDER BY day DESC
`);

// Calibration: get last reset timestamp for an account
const getLastCalibrationReset = db.prepare(`
  SELECT reset_timestamp FROM quota_calibration
  WHERE account_id = ?
  ORDER BY reset_timestamp DESC
  LIMIT 1
`);

// Calibration: sum tokens in a time window for an account
const getTokensInWindow = db.prepare(`
  SELECT
    SUM(tu.input_tokens + tu.output_tokens + tu.cache_creation_tokens) as billable_tokens
  FROM token_usage tu
  JOIN token_sessions ts ON tu.session_id = ts.session_id
  WHERE COALESCE(ts.override_account_id, ts.inferred_account_id) = ?
    AND tu.timestamp > ?
    AND tu.timestamp <= ?
`);

// Calibration: insert a calibration data point
const insertCalibration = db.prepare(`
  INSERT INTO quota_calibration (
    account_id, reset_timestamp, tokens_in_period, percent_at_reset, tokens_per_percent
  ) VALUES (?, ?, ?, ?, ?)
`);

// Calibration: get all calibration points for an account
const getCalibrationData = db.prepare(`
  SELECT * FROM quota_calibration
  WHERE account_id = ?
  ORDER BY reset_timestamp DESC
`);

/**
 * Scan Claude Code JSONL files and import token usage data
 */
function syncTokenUsage() {
  const claudeDir = path.join(os.homedir(), '.claude', 'projects');

  if (!fs.existsSync(claudeDir)) {
    return { success: false, error: 'Claude Code directory not found', sessionsProcessed: 0 };
  }

  let sessionsProcessed = 0;
  let messagesImported = 0;
  const errors = [];

  // Find all project directories
  const projectDirs = fs.readdirSync(claudeDir, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => path.join(claudeDir, d.name));

  const importTransaction = db.transaction(() => {
    for (const projectDir of projectDirs) {
      const projectPath = projectDir.replace(os.homedir(), '~');

      // Find all JSONL files (excluding agent-* files which are subprocesses)
      let jsonlFiles;
      try {
        jsonlFiles = fs.readdirSync(projectDir)
          .filter(f => f.endsWith('.jsonl') && !f.startsWith('agent-'))
          .map(f => path.join(projectDir, f));
      } catch (e) {
        continue;
      }

      for (const jsonlPath of jsonlFiles) {
        try {
          const sessionId = path.basename(jsonlPath, '.jsonl');
          const result = processJsonlFile(jsonlPath, sessionId, projectPath);
          if (result.messagesImported > 0) {
            sessionsProcessed++;
            messagesImported += result.messagesImported;
          }
        } catch (e) {
          errors.push(`${jsonlPath}: ${e.message}`);
        }
      }
    }
  });

  try {
    importTransaction();
  } catch (e) {
    return { success: false, error: e.message, sessionsProcessed: 0 };
  }

  return {
    success: true,
    sessionsProcessed,
    messagesImported,
    errors: errors.length > 0 ? errors : undefined
  };
}

/**
 * Process a single JSONL file and extract token usage
 */
function processJsonlFile(jsonlPath, sessionId, projectPath) {
  const content = fs.readFileSync(jsonlPath, 'utf8');
  const lines = content.split('\n').filter(l => l.trim());

  let firstMessageTs = null;
  let lastMessageTs = null;
  let totalInput = 0;
  let totalOutput = 0;
  let totalCacheCreation = 0;
  let totalCacheRead = 0;
  let messageCount = 0;
  let messagesImported = 0;
  const messagesToInsert = [];

  for (const line of lines) {
    try {
      const entry = JSON.parse(line);

      // Only process assistant messages with usage data
      if (entry.type !== 'assistant' || !entry.message?.usage) {
        continue;
      }

      const timestamp = entry.timestamp;
      const usage = entry.message.usage;
      const model = entry.message.model || 'unknown';
      const messageUuid = entry.uuid;

      if (!timestamp || !messageUuid) continue;

      // Track first/last timestamps
      if (!firstMessageTs || timestamp < firstMessageTs) {
        firstMessageTs = timestamp;
      }
      if (!lastMessageTs || timestamp > lastMessageTs) {
        lastMessageTs = timestamp;
      }

      // Extract token counts
      const inputTokens = usage.input_tokens || 0;
      const outputTokens = usage.output_tokens || 0;
      const cacheCreationTokens = usage.cache_creation_input_tokens || 0;
      const cacheReadTokens = usage.cache_read_input_tokens || 0;

      // Accumulate totals
      totalInput += inputTokens;
      totalOutput += outputTokens;
      totalCacheCreation += cacheCreationTokens;
      totalCacheRead += cacheReadTokens;
      messageCount++;

      // Collect for later insertion (after session is created)
      messagesToInsert.push({
        timestamp,
        model,
        inputTokens,
        outputTokens,
        cacheCreationTokens,
        cacheReadTokens,
        messageUuid
      });
    } catch (e) {
      // Skip malformed lines
      continue;
    }
  }

  if (firstMessageTs) {
    // Infer account from the timestamp of the first message
    const accountResult = inferAccountForTimestamp.get(firstMessageTs);
    const inferredAccountId = accountResult?.account_id || null;

    // Upsert session summary FIRST (so foreign key constraint is satisfied)
    upsertTokenSession.run(
      sessionId,
      projectPath,
      firstMessageTs,
      lastMessageTs,
      inferredAccountId,
      totalInput,
      totalOutput,
      totalCacheCreation,
      totalCacheRead,
      messageCount,
      new Date().toISOString()
    );

    // Now insert individual messages (session record exists now)
    for (const msg of messagesToInsert) {
      const result = insertTokenUsage.run(
        sessionId,
        msg.timestamp,
        msg.model,
        msg.inputTokens,
        msg.outputTokens,
        msg.cacheCreationTokens,
        msg.cacheReadTokens,
        msg.messageUuid
      );
      if (result.changes > 0) {
        messagesImported++;
      }
    }
  }

  return { messagesImported };
}

// Read message from stdin (native messaging protocol)
function getMessage() {
  return new Promise((resolve, reject) => {
    let chunks = [];
    let lengthBuffer = Buffer.alloc(4);
    let bytesRead = 0;
    let messageLength = null;

    process.stdin.on('readable', () => {
      let chunk;
      while ((chunk = process.stdin.read()) !== null) {
        if (messageLength === null) {
          // First 4 bytes are the message length
          const needed = Math.min(4 - bytesRead, chunk.length);
          chunk.copy(lengthBuffer, bytesRead, 0, needed);
          bytesRead += needed;

          if (bytesRead >= 4) {
            messageLength = lengthBuffer.readUInt32LE(0);
            // Handle any extra bytes in this chunk
            if (chunk.length > needed) {
              chunks.push(chunk.slice(needed));
            }
          }
        } else {
          chunks.push(chunk);
        }

        // Check if we have the full message
        const totalLength = chunks.reduce((sum, c) => sum + c.length, 0);
        if (messageLength !== null && totalLength >= messageLength) {
          const messageBuffer = Buffer.concat(chunks).slice(0, messageLength);
          try {
            resolve(JSON.parse(messageBuffer.toString('utf8')));
          } catch (e) {
            reject(e);
          }
          return;
        }
      }
    });

    process.stdin.on('end', () => {
      if (chunks.length > 0) {
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
        } catch (e) {
          reject(e);
        }
      }
    });
  });
}

// Send message to extension
function sendMessage(msg) {
  const json = JSON.stringify(msg);
  const length = Buffer.byteLength(json, 'utf8');
  const buffer = Buffer.alloc(4 + length);
  buffer.writeUInt32LE(length, 0);
  buffer.write(json, 4, 'utf8');
  process.stdout.write(buffer);
}

// Process incoming message
async function processMessage(msg) {
  if (msg.type === 'USAGE_UPDATE') {
    const accountId = msg.accountId || 'default';
    const data = msg.data;
    const timestamp = data.timestamp || new Date().toISOString();

    // Store which browser sent the data (for "Open All Accounts" feature)
    if (msg.browser) {
      upsertSetting.run('last_browser', msg.browser);
    }

    // Prefer flattened fields from new content.js, fall back to sections parsing
    let sessionPercent = data.sessionPercent ?? data.primaryPercent ?? null;
    let weeklyAllPercent = data.weeklyAllPercent ?? null;
    let weeklySonnetPercent = data.weeklySonnetPercent ?? null;
    let sessionReset = data.sessionReset ?? null;
    let weeklyReset = data.weeklyReset ?? null;

    // Fallback: parse from sections if flattened fields not available
    if (data.sections && (weeklyAllPercent === null || weeklySonnetPercent === null)) {
      for (const section of data.sections) {
        if (section.type === 'all_models' && weeklyAllPercent === null) {
          weeklyAllPercent = section.percentUsed;
          if (!weeklyReset) weeklyReset = section.resetTime;
        } else if (section.type === 'sonnet_only' && weeklySonnetPercent === null) {
          weeklySonnetPercent = section.percentUsed;
        }
      }
    }

    // Fallback: parse session reset from rawText if still not found
    if (!sessionReset && data.rawText) {
      const sessionMatch = data.rawText.match(/Resets?\s+in\s+(\d+\s*(?:hr|hour|min|day)[^\n]*)/i);
      if (sessionMatch) {
        sessionReset = 'in ' + sessionMatch[1].trim();
      }
    }

    // Update account (account_name is never overwritten - only set on first insert or via user edit)
    upsertAccount.run(
      accountId,
      data.accountName || null,
      data.email || null,
      data.plan || null,
      timestamp
    );

    // Check for reset: compare with previous reading
    const prevReading = getLatestUsage.get(accountId);
    let resetDetected = false;

    if (prevReading && weeklyAllPercent !== null) {
      const prevPercent = prevReading.weekly_all_percent;
      // Reset detected if usage dropped by more than 5%
      if (prevPercent !== null && prevPercent - weeklyAllPercent > 5) {
        resetDetected = true;

        const currentTime = new Date(timestamp);
        const prevTime = new Date(prevReading.timestamp);

        // Calculate the actual reset time from the previous reading's weekly_reset
        // Pass findPrevious=true since the reset already happened (we're detecting it after the fact)
        let resetTime = parseResetTime(prevReading.weekly_reset, prevReading.timestamp, true);

        // Validate the reset time is within the window between readings
        // If not, this is likely an unexpected reset (promotional, plan change, etc.)
        const isValidScheduledReset = resetTime &&
          resetTime > prevTime &&
          resetTime < currentTime;

        if (!isValidScheduledReset) {
          // Unexpected reset: use midpoint between readings as the reset time
          // This provides a reasonable visual representation without bad timestamps
          const midpointMs = (prevTime.getTime() + currentTime.getTime()) / 2;
          resetTime = new Date(midpointMs);
        }

        // Final safety check: never insert synthetic points in the future
        if (resetTime && resetTime <= currentTime) {
          // Insert two synthetic points to create a vertical drop on the chart
          // Point 1: At the reset time, still at the previous usage level
          const resetTimeISO = resetTime.toISOString();
          insertSyntheticPoint.run(
            accountId,
            resetTimeISO,
            prevReading.primary_percent,
            prevReading.session_percent,
            prevPercent,
            prevReading.weekly_sonnet_percent
          );

          // Point 2: One second after reset, at 0%
          const zeroTime = new Date(resetTime.getTime() + 1000);
          const zeroTimeISO = zeroTime.toISOString();
          insertSyntheticPoint.run(
            accountId,
            zeroTimeISO,
            0,
            0,
            0,
            0
          );

          // Calibration: calculate tokens consumed in this billing period
          try {
            // Find the start of this billing period (previous reset or earliest data)
            const lastCalibration = getLastCalibrationReset.get(accountId);
            const periodStart = lastCalibration?.reset_timestamp || '1970-01-01T00:00:00Z';

            // Sum tokens in the period that just ended
            const tokenResult = getTokensInWindow.get(accountId, periodStart, resetTimeISO);
            const tokensInPeriod = tokenResult?.billable_tokens || 0;

            // Only record calibration if we have meaningful data
            if (tokensInPeriod > 0 && prevPercent > 5) {
              const tokensPerPercent = tokensInPeriod / prevPercent;
              insertCalibration.run(
                accountId,
                resetTimeISO,
                tokensInPeriod,
                prevPercent,
                tokensPerPercent
              );
              // Log for debugging
              const tokensM = (tokensInPeriod / 1_000_000).toFixed(1);
              const tppK = (tokensPerPercent / 1_000).toFixed(0);
              process.stderr.write(`[Calibration] ${accountId}: ${prevPercent}% = ${tokensM}M tokens (${tppK}K/%)\\n`);
            }
          } catch (calibrationError) {
            // Don't fail the main operation if calibration fails
            process.stderr.write(`[Calibration Error] ${calibrationError.message}\\n`);
          }
        }
      }
    }

    // Insert usage record
    insertUsage.run(
      accountId,
      timestamp,
      data.primaryPercent,
      sessionPercent,
      weeklyAllPercent,
      weeklySonnetPercent,
      sessionReset,
      weeklyReset,
      JSON.stringify(data),
      0  // is_synthetic = false
    );

    // Sync token usage from Claude Code JSONL files
    const tokenSync = syncTokenUsage();

    sendMessage({
      success: true,
      accountId,
      percent: data.primaryPercent,
      resetDetected,
      tokenSync: {
        sessionsProcessed: tokenSync.sessionsProcessed,
        messagesImported: tokenSync.messagesImported
      },
      dbPath: DB_FILE
    });

  } else if (msg.type === 'GET_DATA') {
    const accounts = getAllAccounts.all();
    const result = {
      accounts: accounts.map(a => ({
        id: a.id,
        accountName: a.account_name,
        email: a.email,
        plan: a.plan,
        lastUpdated: a.last_updated,
        latestPercent: a.latest_percent
      })),
      dbPath: DB_FILE
    };
    sendMessage({ success: true, data: result });

  } else if (msg.type === 'GET_HISTORY') {
    const accountId = msg.accountId || 'default';
    const limit = msg.limit || 100;
    const history = getAccountHistory.all(accountId, limit);
    sendMessage({ success: true, history });

  } else if (msg.type === 'REORDER_ACCOUNT') {
    // Move an account to the top (lowest sort_order)
    const accountId = msg.accountId;
    if (!accountId) {
      sendMessage({ success: false, error: 'accountId required' });
      return;
    }

    // Set this account to sort_order = -1 (will be lowest)
    // Then normalize all sort orders to 0, 1, 2, ...
    const accounts = getAllAccounts.all();
    const targetIndex = accounts.findIndex(a => a.id === accountId);

    if (targetIndex === -1) {
      sendMessage({ success: false, error: 'Account not found' });
      return;
    }

    // Move target to front, keep others in order
    const reordered = [
      accounts[targetIndex],
      ...accounts.slice(0, targetIndex),
      ...accounts.slice(targetIndex + 1)
    ];

    // Update sort_order for all accounts
    const updateAll = db.transaction(() => {
      reordered.forEach((account, index) => {
        updateAccountSortOrder.run(index, account.id);
      });
    });
    updateAll();

    sendMessage({ success: true, accountId });

  } else if (msg.type === 'SYNC_TOKENS') {
    // Scan Claude Code JSONL files and import token usage
    const result = syncTokenUsage();
    sendMessage(result);

  } else if (msg.type === 'GET_TOKEN_SUMMARY') {
    // Get token usage summary, optionally filtered by time range
    const daysBack = msg.daysBack || 7;
    const cutoffDate = new Date();
    cutoffDate.setDate(cutoffDate.getDate() - daysBack);
    const cutoffStr = cutoffDate.toISOString();

    const byAccount = getTokenSummaryByAccount.all(cutoffStr);
    const daily = getDailyTokensByAccount.all(cutoffStr);
    const sessions = getTokenSessionsSummary.all();

    sendMessage({
      success: true,
      summary: {
        byAccount,
        daily,
        recentSessions: sessions.slice(0, 20)
      }
    });

  } else {
    sendMessage({ success: false, error: 'Unknown message type' });
  }
}

// Main
async function main() {
  try {
    const msg = await getMessage();
    await processMessage(msg);
  } catch (e) {
    sendMessage({ success: false, error: e.message });
  } finally {
    db.close();
  }
}

main();
