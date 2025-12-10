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
    email TEXT,
    plan TEXT,
    last_updated TEXT
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

// Prepared statements
const insertAccount = db.prepare(`
  INSERT OR REPLACE INTO accounts (id, email, plan, last_updated)
  VALUES (?, ?, ?, ?)
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

    // Extract percentages from sections
    let sessionPercent = data.primaryPercent;
    let weeklyAllPercent = null;
    let weeklySONnetPercent = null;
    let sessionReset = null;
    let weeklyReset = null;

    if (data.sections) {
      for (const section of data.sections) {
        if (section.title && section.title.includes('session')) {
          sessionPercent = section.percent;
          sessionReset = section.resetTime;
        } else if (section.title && section.title.includes('All models')) {
          weeklyAllPercent = section.percent;
          weeklyReset = section.resetTime;
        } else if (section.title && section.title.includes('Sonnet')) {
          weeklySONnetPercent = section.percent;
        }
      }
    }

    // Update account
    insertAccount.run(
      accountId,
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
      weeklySONnetPercent,
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
