#if !canImport(Combine)
// Minimal stand-ins for Combine's observation types so the portable core
// (UsageStore, OAuthPoller, UpdateChecker) compiles on Linux. Headless mode
// has no UI, so nothing ever observes these — plain storage is enough.

protocol ObservableObject: AnyObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
#endif
