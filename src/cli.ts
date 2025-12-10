#!/usr/bin/env node
import { Command } from "commander";
import { readExportedData, findLatestExports, UsageData } from "./reader.js";
import Table from "cli-table3";
import chalk from "chalk";
import { readFileSync } from "fs";

const program = new Command();

program
  .name("claude-monitor")
  .description("Monitor Claude usage across multiple accounts")
  .version("0.1.0");

program
  .command("status")
  .description("Show usage status from exported JSON files")
  .option("-d, --dir <directory>", "Directory containing exported JSON files", ".")
  .option("-r, --raw", "Show raw data")
  .action(async (options) => {
    // First, check for exported files in the directory
    const files = findLatestExports(options.dir);

    if (files.length === 0) {
      console.log(chalk.yellow("\nNo exported usage data found.\n"));
      console.log("To collect usage data:");
      console.log("1. Install the browser extension from ./extension/");
      console.log("2. Visit https://claude.ai/settings/usage in your browser");
      console.log("3. Click 'Export Data (JSON)' in the extension popup");
      console.log("4. Run this command in the same directory as the exported file\n");
      return;
    }

    // Read all exported files
    const results: UsageData[] = [];
    for (const file of files) {
      try {
        const content = readFileSync(file, "utf-8");
        const data = JSON.parse(content);

        if (data.lastUpdate) {
          const accountName = file.split("/").pop()?.replace(/\.json$/, "").replace(/^claude-usage-/, "") || "unknown";
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

    if (options.raw) {
      displayRawData(results);
    } else {
      displayUsageTable(results);
    }
  });

program
  .command("import <file>")
  .description("Import and display a specific exported JSON file")
  .action(async (file: string) => {
    try {
      const content = readFileSync(file, "utf-8");
      const data = JSON.parse(content);

      console.log(chalk.bold("\nImported Usage Data:"));
      console.log("=".repeat(60));

      if (data.lastUpdate) {
        console.log(chalk.cyan("\nLast Update:"));
        console.log(`  Timestamp: ${data.lastUpdate.timestamp}`);
        console.log(`  Percentages: ${data.lastUpdate.percentages?.join(", ") || "none"}`);
        console.log(`  Reset: ${data.lastUpdate.resetInfo || "unknown"}`);
      }

      if (data.usageHistory) {
        console.log(chalk.cyan(`\nHistory (${data.usageHistory.length} entries):`));
        for (const entry of data.usageHistory.slice(0, 5)) {
          console.log(`  - ${entry.timestamp}: ${entry.percentages?.[0] || "?"}%`);
        }
        if (data.usageHistory.length > 5) {
          console.log(`  ... and ${data.usageHistory.length - 5} more`);
        }
      }

      console.log();
    } catch (e) {
      console.error(`Error reading file: ${e}`);
    }
  });

// Default: show status
program.action(() => {
  program.commands.find((c) => c.name() === "status")?.action({ dir: "." });
});

function displayUsageTable(data: UsageData[]): void {
  if (data.length === 0) {
    console.log(chalk.yellow("\nNo usage data available."));
    return;
  }

  const table = new Table({
    head: [
      chalk.cyan("Account/File"),
      chalk.cyan("Usage"),
      chalk.cyan("Reset"),
      chalk.cyan("Last Updated"),
    ],
    colWidths: [25, 22, 30, 25],
    style: {
      head: [],
      border: [],
    },
  });

  for (const account of data) {
    const percentColor = getPercentColor(account.percentUsed);
    const bar = createProgressBar(account.percentUsed, 10);
    const time = account.timestamp
      ? new Date(account.timestamp).toLocaleString()
      : "-";

    table.push([
      account.accountName,
      `${bar} ${percentColor(account.percentUsed.toFixed(0) + "%")}`,
      account.resetTime.slice(0, 28) || "-",
      time,
    ]);
  }

  console.log();
  console.log(chalk.bold("Claude Usage Monitor"));
  console.log();
  console.log(table.toString());
  console.log();
}

function getPercentColor(percent: number): (text: string) => string {
  if (percent >= 90) return chalk.red;
  if (percent >= 70) return chalk.yellow;
  return chalk.green;
}

function createProgressBar(percent: number, width: number): string {
  const filled = Math.round((percent / 100) * width);
  const empty = width - filled;

  const filledChar = "█";
  const emptyChar = "░";

  const color = getPercentColor(percent);
  return color(filledChar.repeat(filled)) + chalk.gray(emptyChar.repeat(empty));
}

function displayRawData(data: UsageData[]): void {
  console.log(chalk.bold("\nRaw Usage Data:"));
  console.log("=".repeat(60));

  for (const account of data) {
    console.log(chalk.cyan(`\n[${account.accountName}]`));
    console.log("-".repeat(40));
    console.log(`Usage: ${account.percentUsed}%`);
    console.log(`Reset: ${account.resetTime || "unknown"}`);
    console.log(`Timestamp: ${account.timestamp}`);
    console.log("\nPage text (truncated):");
    console.log(account.raw?.slice(0, 1500) || "No data");
    console.log();
  }
}

program.parse();
