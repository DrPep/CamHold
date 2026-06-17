import Foundation
import CoreMediaIO

/// Owns one `kCMIODevicePropertyDeviceIsRunningSomewhere` listener per
/// watched device. Edges are dispatched on a private serial queue
/// (`camhold.cmio.listener`); the queue **only posts events** through
/// `onEdge` — it never touches `AVCaptureSession`. The §9d coordinator hops
/// to its own queue before mutating any state. See `DELTA.md §F.3`.
final class CMIORunningListener {

    /// `(deviceID, isRunningSomewhere)` edge.
    typealias Edge = (deviceID: CMIODeviceID, isRunning: Bool)

    private let queue = DispatchQueue(label: "camhold.cmio.listener")
    private var registrations: [CMIODeviceID: CMIOObjectPropertyListenerBlock] = [:]

    /// Last-known running state per device, used to coalesce duplicate
    /// edges (the API will fire on every property write, not just on
    /// `false → true` transitions).
    private var lastKnown: [CMIODeviceID: Bool] = [:]

    var onEdge: ((Edge) -> Void)?

    deinit { stopAll() }

    /// Begin watching `deviceID`. Idempotent: a second call for the same ID
    /// is a no-op. The current value of `IsRunningSomewhere` is **not**
    /// emitted synchronously — callers should query it explicitly via
    /// `CMIODevice.isRunningSomewhere(...)` if they need a starting state.
    func watch(deviceID: CMIODeviceID) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.registrations[deviceID] == nil else { return }
            self.lastKnown[deviceID] = CMIODevice.isRunningSomewhere(deviceID)

            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let now = CMIODevice.isRunningSomewhere(deviceID)
                let prev = self.lastKnown[deviceID]
                if prev == now { return } // coalesce
                self.lastKnown[deviceID] = now
                let edge: Edge = (deviceID, now)
                self.onEdge?(edge)
            }
            if let stored = CMIODevice.addIsRunningSomewhereListener(
                deviceID: deviceID, queue: self.queue, block: block) {
                self.registrations[deviceID] = stored
            }
        }
    }

    /// Stop watching `deviceID`. Safe to call for an unwatched device.
    func unwatch(deviceID: CMIODeviceID) {
        queue.async { [weak self] in
            guard let self,
                  let block = self.registrations.removeValue(forKey: deviceID) else { return }
            CMIODevice.removePropertyListener(
                deviceID: deviceID,
                selector: CMIODevice.isRunningSomewhereSelector,
                queue: self.queue,
                block: block)
            self.lastKnown.removeValue(forKey: deviceID)
        }
    }

    /// Tear down all registrations. Called from `deinit` and from
    /// `applicationWillTerminate` for clean shutdown.
    func stopAll() {
        queue.sync {
            for (deviceID, block) in registrations {
                CMIODevice.removePropertyListener(
                    deviceID: deviceID,
                    selector: CMIODevice.isRunningSomewhereSelector,
                    queue: queue,
                    block: block)
            }
            registrations.removeAll()
            lastKnown.removeAll()
        }
    }
}
