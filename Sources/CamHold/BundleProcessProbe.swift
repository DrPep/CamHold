import AppKit
import Darwin

/// "Is any process from this bundle ID currently running?"
///
/// Primary path is `NSRunningApplication.runningApplications(withBundleIdentifier:)`
/// because §9d explicitly warns against name-based matching and this API is
/// bundle-ID-typed by construction. The `proc_listallpids` fallback is used
/// only when explicitly requested (e.g. for headless helpers that don't
/// register with `NSWorkspace`).
enum BundleProcessProbe {

    /// Returns `true` iff at least one running app advertises `bundleID`.
    static func isAnyAppRunning(withBundleID bundleID: String) -> Bool {
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
            return true
        }
        return false
    }

    /// BSD-level fallback: walk `proc_listallpids`, look up each pid's
    /// executable path, resolve the enclosing `.app` (if any), and compare
    /// `CFBundleIdentifier`. Slower than `NSRunningApplication` and only
    /// here for the helper-process case described in §9d.
    static func isAnyProcessRunning(withBundleID bundleID: String) -> Bool {
        // First ask `proc_listallpids` for the buffer size.
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return false }
        let count = Int(needed) // approximate upper bound
        var pids = [pid_t](repeating: 0, count: count + 32)

        let bytes = pids.withUnsafeMutableBufferPointer { buf -> Int32 in
            // Swift imports the second arg as `UnsafeMutableRawPointer?` /
            // `Int32`; we need bytes, not pid count.
            let raw = UnsafeMutableRawPointer(buf.baseAddress)
            return proc_listallpids(raw, Int32(buf.count * MemoryLayout<pid_t>.size))
        }
        guard bytes > 0 else { return false }
        let pidCount = Int(bytes) / MemoryLayout<pid_t>.size

        // `PROC_PIDPATHINFO_MAXSIZE` (= 4 * MAXPATHLEN) is exposed as a C
        // macro that doesn't import into Swift; inline the value here.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for i in 0..<pidCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            let n = proc_pidpath(pid, &path, UInt32(path.count))
            guard n > 0 else { continue }
            let exePath = String(cString: path)
            // Walk up to the enclosing `.app` bundle, if any.
            guard let appURL = enclosingAppBundleURL(forExecutablePath: exePath) else { continue }
            if let bundle = Bundle(url: appURL),
               bundle.bundleIdentifier == bundleID {
                return true
            }
        }
        return false
    }

    private static func enclosingAppBundleURL(forExecutablePath exePath: String) -> URL? {
        var url = URL(fileURLWithPath: exePath)
        // exePath is typically `/…/Foo.app/Contents/MacOS/Foo`.
        for _ in 0..<5 {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return url }
            if url.path == "/" { return nil }
        }
        return nil
    }
}
