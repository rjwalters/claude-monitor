#!/usr/bin/env node
/**
 * Backfill synthetic reset points for existing data
 */

const Database = require('better-sqlite3');
const path = require('path');
const os = require('os');

const DB_FILE = path.join(os.homedir(), '.claude-monitor/usage.db');
const db = new Database(DB_FILE);

// Same parseResetTime function as in native host
function parseResetTime(resetStr, referenceTimestamp) {
  if (!resetStr) return null;
  const refDate = new Date(referenceTimestamp);

  // Try relative format: "in X hr Y min"
  const relativeMatch = resetStr.match(/in\s+(\d+)\s*(?:hr|hour)s?\s*(?:(\d+)\s*min)?/i);
  if (relativeMatch) {
    const hours = parseInt(relativeMatch[1], 10);
    const minutes = relativeMatch[2] ? parseInt(relativeMatch[2], 10) : 0;
    return new Date(refDate.getTime() + (hours * 60 + minutes) * 60 * 1000);
  }

  // Try absolute format: "Thu 10:00 AM"
  const absoluteMatch = resetStr.match(/([A-Za-z]{3})\s+(\d{1,2}):(\d{2})\s*(AM|PM)/i);
  if (absoluteMatch) {
    const dayName = absoluteMatch[1];
    let hour = parseInt(absoluteMatch[2], 10);
    const minute = parseInt(absoluteMatch[3], 10);
    const ampm = absoluteMatch[4].toUpperCase();

    if (ampm === 'PM' && hour !== 12) hour += 12;
    if (ampm === 'AM' && hour === 12) hour = 0;

    const dayMap = { 'Sun': 0, 'Mon': 1, 'Tue': 2, 'Wed': 3, 'Thu': 4, 'Fri': 5, 'Sat': 6 };
    const targetDay = dayMap[dayName];
    if (targetDay === undefined) return null;

    const resetTime = new Date(refDate);
    resetTime.setHours(hour, minute, 0, 0);

    const currentDay = refDate.getDay();
    let daysUntil = targetDay - currentDay;
    if (daysUntil < 0) daysUntil += 7;
    if (daysUntil === 0 && resetTime <= refDate) daysUntil = 7;

    resetTime.setDate(resetTime.getDate() + daysUntil);
    return resetTime;
  }
  return null;
}

// Get all readings ordered by account and timestamp
const readings = db.prepare(`
  SELECT * FROM usage_history
  WHERE is_synthetic = 0 OR is_synthetic IS NULL
  ORDER BY account_id, timestamp ASC
`).all();

const insertSynthetic = db.prepare(`
  INSERT INTO usage_history (
    account_id, timestamp, primary_percent, session_percent,
    weekly_all_percent, weekly_sonnet_percent, session_reset, weekly_reset, raw_data, is_synthetic
  ) VALUES (?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1)
`);

let syntheticCount = 0;
let prev = null;

for (const curr of readings) {
  if (prev && prev.account_id === curr.account_id) {
    const prevPercent = prev.weekly_all_percent;
    const currPercent = curr.weekly_all_percent;

    // Detect reset: usage dropped by more than 5%
    if (prevPercent !== null && currPercent !== null && prevPercent - currPercent > 5) {
      const resetTime = parseResetTime(prev.weekly_reset, prev.timestamp);

      if (resetTime) {
        // Check synthetic points don't already exist at this time
        const existing = db.prepare(`
          SELECT COUNT(*) as cnt FROM usage_history
          WHERE account_id = ? AND is_synthetic = 1
          AND timestamp BETWEEN ? AND ?
        `).get(curr.account_id,
               new Date(resetTime.getTime() - 60000).toISOString(),
               new Date(resetTime.getTime() + 60000).toISOString());

        if (existing.cnt === 0) {
          // Point 1: At reset time, previous usage level
          insertSynthetic.run(
            curr.account_id,
            resetTime.toISOString(),
            prev.primary_percent,
            prev.session_percent,
            prevPercent,
            prev.weekly_sonnet_percent
          );

          // Point 2: 1 second later, at 0%
          const zeroTime = new Date(resetTime.getTime() + 1000);
          insertSynthetic.run(
            curr.account_id,
            zeroTime.toISOString(),
            0, 0, 0, 0
          );

          syntheticCount += 2;
          console.log('Reset:', prev.timestamp, '(' + prevPercent + '%) ->', curr.timestamp, '(' + currPercent + '%) | Synthetic at', resetTime.toISOString());
        }
      }
    }
  }
  prev = curr;
}

db.close();
console.log('\nBackfill complete: inserted ' + syntheticCount + ' synthetic points');
