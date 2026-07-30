#if !os(macOS)
// Linux entry point: there is no UI, so the binary is always the headless
// poll loop. (On macOS the entry lives in main.swift and dispatches here
// when launched with --headless.)
@main
enum ClaudeMonitorEntry {
    static func main() {
        // `accounts export|import` is a one-shot CLI operation, distinct from
        // the always-on poll loop below.
        if CommandLine.arguments.dropFirst().first == "accounts" {
            AccountSyncCLI.main(Array(CommandLine.arguments.dropFirst(2)))
        } else if CommandLine.arguments.dropFirst().first == "selftest" {
            SelfTest.main(Array(CommandLine.arguments.dropFirst(2)))
        } else {
            HeadlessRunner.main()
        }
    }
}
#endif
