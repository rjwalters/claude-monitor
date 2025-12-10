import { readFileSync, readdirSync, statSync } from "fs";
import { join, resolve } from "path";

export interface ExtensionData {
  lastUpdate?: {
    timestamp: string;
    url: string;
    percentages: string[];
    resetInfo: string;
    rawText: string;
  };
  usageHistory?: Array<{
    timestamp: string;
    url: string;
    percentages: string[];
    resetInfo: string;
    rawText: string;
  }>;
}

export interface UsageData {
  accountName: string;
  percentUsed: number;
  resetTime: string;
  timestamp: string;
  raw?: string;
}

export function readExportedData(dataDir: string): UsageData[] {
  const results: UsageData[] = [];
  const dir = resolve(dataDir);

  try {
    const files = readdirSync(dir).filter((f) => f.endsWith(".json"));

    for (const file of files) {
      const filePath = join(dir, file);
      try {
        const content = readFileSync(filePath, "utf-8");
        const data: ExtensionData = JSON.parse(content);

        if (data.lastUpdate) {
          const accountName = file.replace(/\.json$/, "").replace(/^claude-usage-/, "");
          const percent = data.lastUpdate.percentages?.[0]
            ? parseFloat(data.lastUpdate.percentages[0])
            : 0;

          results.push({
            accountName,
            percentUsed: percent,
            resetTime: data.lastUpdate.resetInfo || "",
            timestamp: data.lastUpdate.timestamp,
            raw: data.lastUpdate.rawText,
          });
        }
      } catch (e) {
        console.error(`Error reading ${file}:`, e);
      }
    }
  } catch (e) {
    // Directory doesn't exist or other error
  }

  return results;
}

export function findLatestExports(searchDir: string = "."): string[] {
  const files: string[] = [];
  const dir = resolve(searchDir);

  try {
    const entries = readdirSync(dir);
    for (const entry of entries) {
      if (entry.startsWith("claude-usage-") && entry.endsWith(".json")) {
        files.push(join(dir, entry));
      }
    }
  } catch {
    // Ignore errors
  }

  // Sort by modification time, newest first
  return files.sort((a, b) => {
    try {
      return statSync(b).mtime.getTime() - statSync(a).mtime.getTime();
    } catch {
      return 0;
    }
  });
}
