import AppKit

/// Wraps `NSWorkspace.shared.notificationCenter` for app launch/terminate
/// notifications, filtered against a live set of bundle IDs. Events are
/// emitted on the main queue (matching `NSWorkspace`'s delivery thread)
/// so the coordinator can hop to its own serial queue from there.
final class WorkspaceAppObserver {

    enum EventKind {
        case launched
        case terminated
    }

    struct Event {
        let bundleID: String
        let kind: EventKind
    }

    /// Live set of watched bundle IDs. The observer reads this on every
    /// notification, so callers can mutate it in place (on main) and the
    /// next event will be filtered correctly.
    var watchedBundleIDs: Set<String> = []

    var onEvent: ((Event) -> Void)?

    private var launchToken: NSObjectProtocol?
    private var terminateToken: NSObjectProtocol?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        launchToken = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(note: note, kind: .launched)
        }
        terminateToken = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.handle(note: note, kind: .terminated)
        }
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        if let t = launchToken    { center.removeObserver(t); launchToken = nil }
        if let t = terminateToken { center.removeObserver(t); terminateToken = nil }
    }

    deinit { stop() }

    private func handle(note: Notification, kind: EventKind) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleID = app.bundleIdentifier,
            watchedBundleIDs.contains(bundleID)
        else { return }
        onEvent?(Event(bundleID: bundleID, kind: kind))
    }
}
