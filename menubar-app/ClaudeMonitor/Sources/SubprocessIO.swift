import Foundation
// `signal` / `sigaction` / `SIGPIPE` / `SIG_IGN` are POSIX, not Foundation:
// Linux's swift-corelibs-foundation does not re-export them, so the platform
// module has to be imported explicitly for the headless build.
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The two things every `Process` in this package needs to get right, spelled
/// once (#202).
///
/// Both were previously spelled per-call-site — `AccountSyncRemote` installed
/// the SIGPIPE guard lazily "so it covers every caller of `runProcess`", which
/// was true and also beside the point, because `CodexAppServerClient` is not one
/// of those callers and writes to a child's stdin too. And both call sites
/// independently drained their child's pipes with `FileHandle.readabilityHandler`,
/// resting on an EOF contract that **does not hold on Linux** (see `PipeDrain`).
/// Keeping one shared implementation is what stops the next subprocess call site
/// from re-deriving either rule slightly wrong.
enum SubprocessIO {
    /// Ignore SIGPIPE process-wide, exactly once.
    ///
    /// **Every code path that writes to a child's stdin must call this first.**
    /// A child that exits before reading (ssh failing fast on a refused
    /// connection; `codex` rejecting a CLI argument and exiting 2 — #184's exact
    /// shape) leaves the parent writing into a pipe with no reader, and at
    /// SIGPIPE's default disposition that *kills this process* — exit 141, no
    /// diagnostic, no `debug.log` line, nothing persisted to
    /// `oauth_credentials.last_error`. With the signal ignored the same write
    /// returns EPIPE, which the throwing `write(contentsOf:)` spellings at both
    /// call sites already surface as a catchable Swift error.
    ///
    /// Idempotent and cheap: a `static let` initializer is run-once and
    /// thread-safe, so this is a no-op after the first call.
    static func ignoreSIGPIPE() { _ = sigpipeIgnored }

    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()

    /// True when SIGPIPE's current disposition is `SIG_IGN`.
    ///
    /// A read-only `sigaction` probe rather than `signal(SIGPIPE, SIG_IGN)`'s
    /// return value: the latter would *install* the very disposition it reports,
    /// which is useless to a self-test asking whether some other code path
    /// installed it.
    static var sigpipeIsIgnored: Bool {
        var current = sigaction()
        guard sigaction(SIGPIPE, nil, &current) == 0 else { return false }
        #if canImport(Glibc)
        let handler = current.__sigaction_handler.sa_handler
        #else
        let handler = current.__sigaction_u.__sa_handler
        #endif
        return handlerBits(handler) == handlerBits(SIG_IGN)
    }

    /// C function pointers are not `Equatable` in Swift, so dispositions are
    /// compared by address. `SIG_DFL` is address 0, which is also what `nil`
    /// maps to — harmless, since both answer "not ignored".
    private static func handlerBits(_ handler: (@convention(c) (Int32) -> Void)?) -> UInt {
        handler.map { UInt(bitPattern: unsafeBitCast($0, to: UnsafeRawPointer.self)) } ?? 0
    }
}

/// Reads one child-process pipe to EOF on a dedicated thread.
///
/// **Why not `FileHandle.readabilityHandler`.** Both subprocess call sites used
/// to drain with a readability callback and treat the documented empty-chunk
/// callback as the EOF signal. That contract is not honoured by
/// swift-corelibs-foundation: `readabilityHandler` is backed by a libdispatch
/// read source, and when a child writes and then exits, the kernel makes the
/// data *and* the hangup available in the same epoll wakeup — the source fires
/// once with the bytes, is torn down, and **the terminating zero-byte callback
/// is never delivered**. Reduced to 15 lines and measured in a stock `swift:6.1`
/// container, a child that runs `echo hi >&2; exit 3` loses that callback on
/// roughly two runs in three; a child that writes *nothing* before exiting never
/// loses it, which is exactly why this stayed invisible for so long — the stream
/// that carries no output always completed, and only the one carrying the
/// diagnostic hung.
///
/// The cost of that was not a flaky test but a **permanent hang**: the drain's
/// `waitForEOF()` is an unbounded semaphore wait, so `accounts push` to a host
/// whose `ssh` printed an error and exited wedged the whole fan-out forever
/// (#202 — reproduced on the first iteration of a single-CPU container, on
/// iteration ~160 of an 18-CPU one, and observed on macOS never, which is why CI
/// stayed green while the documented Linux verification path could not run).
///
/// A blocking read on a thread this type owns has no such contract to get wrong:
/// `read()` returning 0 *is* EOF, on every platform, with no event source in
/// between. It is also strictly better for the ordering invariant
/// `CodexLineStream` depends on — one thread reading one fd delivers chunks in
/// byte order by construction, where the callback version depended on Foundation
/// promising serial delivery.
///
/// `@unchecked Sendable` with a named invariant: `buffer` is touched only under
/// `lock`, `handle` is immutable, and `finished` is signalled exactly once by the
/// drain thread.
final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private let handle: FileHandle
    private let onChunk: (@Sendable (Data) -> Void)?
    private var buffer = Data()
    private var reachedEOF = false

    /// - Parameters:
    ///   - handle: the *read* end of the pipe. This object keeps it alive for
    ///     the lifetime of the drain thread, so the fd cannot be closed out from
    ///     under a blocked `read()` by a `FileHandle` deinit elsewhere.
    ///   - onChunk: called on the drain thread with each non-empty chunk in
    ///     arrival order, then exactly once with an empty `Data` marking EOF —
    ///     the same shape the readability callback promised, now actually
    ///     guaranteed. Pass `nil` to accumulate instead and read the result from
    ///     `waitForEOF()`.
    init(_ handle: FileHandle, onChunk: (@Sendable (Data) -> Void)? = nil) {
        self.handle = handle
        self.onChunk = onChunk
        let thread = Thread { [self] in drainToEOF() }
        thread.name = "claude-monitor.pipe-drain"
        // Well above what a read loop needs; Foundation's default for a `Thread`
        // varies by platform and a 512 KiB floor keeps that from mattering.
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private func drainToEOF() {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if let onChunk = onChunk {
                onChunk(chunk)
            } else {
                lock.lock()
                buffer.append(chunk)
                lock.unlock()
            }
        }
        onChunk?(Data())
        lock.lock()
        reachedEOF = true
        lock.unlock()
        finished.signal()
    }

    /// True once the drain thread has seen EOF and handed over everything it read.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEOF
    }

    /// Blocks the calling thread until the child closed this pipe. Returns
    /// everything read, or empty when a chunk handler consumed it instead.
    ///
    /// Unbounded on purpose at the `accounts push` call site: the child is
    /// always waited on right afterwards, and the *previous* bug was precisely
    /// that this could never return. It now returns as soon as the write end is
    /// gone, which the kernel guarantees once the child exits.
    @discardableResult
    func waitForEOF() -> Data {
        finished.wait()
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    /// Bounded wait, then release the fd — the teardown form for a caller that
    /// has already killed the child and must not be pinned by a pathological one.
    ///
    /// **The handle is closed only if the drain finished.** Closing an fd that
    /// another thread is blocked reading is undefined behaviour (the number can
    /// be recycled under it), so a timed-out drain keeps ownership and the fd is
    /// released when its thread finally returns and the last reference drops.
    ///
    /// `async` and polling rather than a semaphore wait, for the same reason
    /// `CodexAppServerClient.waitForExit` polls: the caller is a Swift
    /// concurrency-pool thread, and parking one on a blocking wait is what this
    /// package spent an earlier bug learning not to do. In practice the child is
    /// already gone by the first check and this returns without suspending.
    func finishAndClose(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isFinished {
            if Date() >= deadline { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? handle.close()
    }
}
