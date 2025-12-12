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

  CREATE INDEX IF NOT EXISTS idx_usage_account ON usage_history(account_id);
  CREATE INDEX IF NOT EXISTS idx_usage_timestamp ON usage_history(timestamp DESC);
`);

// Migration: Add sort_order column if it doesn't exist
try {
  db.exec(`ALTER TABLE accounts ADD COLUMN sort_order INTEGER DEFAULT 0`);
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
    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data
  ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
`);

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
      JSON.stringify(data)
    );

    sendMessage({
      success: true,
      accountId,
      percent: data.primaryPercent,
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
