#if !os(macOS)
// Linux entry point: there is no UI, so the binary is always the headless
// poll loop. (On macOS the entry lives in main.swift and dispatches here
// when launched with --headless.)
@main
enum ClaudeMonitorEntry {
    static func main() {
        HeadlessRunner.main()
    }
}
#endif
