import AppKit

// Must run before anything that can crash: records launches, uncaught
// exceptions and fatal signals in ~/.config/voicepaste/crash.log.
CrashLog.install()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
