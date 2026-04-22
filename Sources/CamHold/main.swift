import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // No Dock icon (redundant with LSUIElement but safe).
app.run()
