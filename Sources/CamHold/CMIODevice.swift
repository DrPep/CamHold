import Foundation
import CoreMediaIO

/// Thin Swift wrapper over the CoreMediaIO C API. Verified in `DELTA.md §C`
/// that all the symbols we need import directly into Swift, so no bridging
/// header is required — this file just hides the `OSStatus`/property-address
/// boilerplate.
enum CMIODevice {

    // MARK: - Property selectors

    /// `kCMIODevicePropertyDeviceMaster` was renamed to
    /// `kCMIODevicePropertyDeviceControl` in macOS 12. The two FourCC
    /// selectors resolve against the same property in practice; we use the
    /// new name everywhere to keep the build warning-free on supported OSes.
    // The Swift overlay imports the FourCC constants as `Int`; cast through
    // `UInt32` to land on `CMIOObjectPropertySelector`.
    static let deviceControlSelector: CMIOObjectPropertySelector =
        CMIOObjectPropertySelector(kCMIODevicePropertyDeviceControl)

    static let isRunningSomewhereSelector: CMIOObjectPropertySelector =
        CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere)

    // MARK: - Errors

    enum Error: Swift.Error, CustomStringConvertible {
        case osStatus(OSStatus, String)
        case notFound(String)

        var description: String {
            switch self {
            case let .osStatus(s, ctx): return "CMIODevice OSStatus \(s) (\(ctx))"
            case let .notFound(ctx):    return "CMIODevice not found: \(ctx)"
            }
        }
    }

    // MARK: - Helpers

    private static func address(_ selector: CMIOObjectPropertySelector,
                                scope: CMIOObjectPropertyScope = CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                element: CMIOObjectPropertyElement = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    /// Enumerate every `CMIODeviceID` known to the system.
    static func allDeviceIDs() throws -> [CMIODeviceID] {
        var addr = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &dataSize)
        guard sizeStatus == noErr else {
            throw Error.osStatus(sizeStatus, "GetPropertyDataSize(Devices)")
        }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard count > 0 else { return [] }

        var ids = [CMIODeviceID](repeating: 0, count: count)
        var used: UInt32 = dataSize
        let getStatus = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil,
                dataSize, &used, buf.baseAddress!)
        }
        guard getStatus == noErr else {
            throw Error.osStatus(getStatus, "GetPropertyData(Devices)")
        }
        return ids
    }

    /// Read a CFString-valued property (e.g. `DeviceUID`, `ModelUID`).
    static func stringProperty(_ selector: CMIOObjectPropertySelector,
                               of deviceID: CMIODeviceID) -> String? {
        var addr = address(selector)
        var dataSize: UInt32 = 0
        let sizeStatus = CMIOObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize == UInt32(MemoryLayout<CFString>.size) else {
            return nil
        }
        var value: Unmanaged<CFString>?
        var used: UInt32 = dataSize
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(dataSize)) { raw in
                CMIOObjectGetPropertyData(deviceID, &addr, 0, nil, dataSize, &used, raw)
            }
        }
        guard status == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    /// Resolve an `AVCaptureDevice.uniqueID` to a `CMIODeviceID` by scanning
    /// `kCMIOHardwarePropertyDevices` and matching `kCMIODevicePropertyDeviceUID`.
    /// AVFoundation does not expose this mapping directly.
    static func deviceID(forUniqueID uniqueID: String) -> CMIODeviceID? {
        guard let ids = try? allDeviceIDs() else { return nil }
        for id in ids {
            if let uid = stringProperty(
                CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID),
                of: id), uid == uniqueID {
                return id
            }
        }
        return nil
    }

    /// Read `kCMIODevicePropertyDeviceIsRunningSomewhere` for a device.
    static func isRunningSomewhere(_ deviceID: CMIODeviceID) -> Bool {
        var addr = address(isRunningSomewhereSelector)
        var value: UInt32 = 0
        var used: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(
            deviceID, &addr, 0, nil, used, &used, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    /// Read the controlling PID via `kCMIODevicePropertyDeviceControl`. The
    /// property is only populated while some process holds
    /// `lockForConfiguration`; expect `0` (or `-1`) most of the time. Returns
    /// `nil` if the property is unavailable on this device.
    static func devicePID(_ deviceID: CMIODeviceID) -> pid_t? {
        var addr = address(deviceControlSelector)
        // The property data is documented as a UInt32 PID.
        var value: UInt32 = 0
        var used: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        let status = CMIOObjectGetPropertyData(
            deviceID, &addr, 0, nil, used, &used, &value)
        guard status == noErr else { return nil }
        return pid_t(bitPattern: value)
    }

    /// Register an `IsRunningSomewhere` listener block. The returned object
    /// is the opaque handle CoreMediaIO requires for `RemovePropertyListenerBlock`.
    /// Caller must retain it for the lifetime of the listener.
    static func addIsRunningSomewhereListener(
        deviceID: CMIODeviceID,
        queue: DispatchQueue,
        block: @escaping CMIOObjectPropertyListenerBlock
    ) -> CMIOObjectPropertyListenerBlock? {
        var addr = address(isRunningSomewhereSelector)
        let status = CMIOObjectAddPropertyListenerBlock(deviceID, &addr, queue, block)
        guard status == noErr else {
            NSLog("CamHold: AddPropertyListenerBlock failed: \(status)")
            return nil
        }
        return block
    }

    static func removePropertyListener(
        deviceID: CMIODeviceID,
        selector: CMIOObjectPropertySelector,
        queue: DispatchQueue,
        block: @escaping CMIOObjectPropertyListenerBlock
    ) {
        var addr = address(selector)
        let status = CMIOObjectRemovePropertyListenerBlock(deviceID, &addr, queue, block)
        if status != noErr {
            NSLog("CamHold: RemovePropertyListenerBlock failed: \(status)")
        }
    }
}
