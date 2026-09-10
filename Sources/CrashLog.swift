import AppKit
import Darwin
import Foundation

/// Persistent crash diary at `~/.config/voicepaste/crash.log`.
///
/// macOS writes `.ips` reports to `~/Library/Logs/DiagnosticReports`, but they
/// omit the NSException reason — the one line that explains an AVFAudio
/// crash — and are easy to overlook. This handler appends, in order:
///
///   - a `launch` line per session, preceded by a note if the previous
///     session never wrote its `exit` line (pointing at the matching `.ips`
///     report when one exists);
///   - for an uncaught NSException: name, reason and the call stack at the
///     throw point;
///   - for a fatal signal (SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGFPE): the
///     signal name and a native backtrace;
///   - for SIGTERM (launchd restart, `pkill`): a clean-exit line.
///
/// The signal paths only use async-signal-safe calls — `write(2)`,
/// `backtrace_symbols_fd`, `unlink`, `_exit` — on a file descriptor opened at
/// install time. Everything else runs in a normal context.
enum CrashLog {
    static let logURL = Config.configDir.appendingPathComponent("crash.log")
    private static let sessionURL = Config.configDir.appendingPathComponent("session.json")
    private static let sessionStart = Date()
    private static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE]

    // Shared with the C signal handlers, which cannot capture context.
    nonisolated(unsafe) private static var fd: Int32 = -1
    nonisolated(unsafe) private static var sessionPathC: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var exceptionLogged = false

    private struct SessionMarker: Codable {
        var pid: Int32
        var startedAt: TimeInterval
    }

    /// Call once, before `NSApplication.run()`.
    static func install() {
        try? FileManager.default.createDirectory(at: Config.configDir, withIntermediateDirectories: true)
        fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        sessionPathC = strdup(sessionURL.path)

        notePreviousSession()
        writeSessionMarker()
        append("==== \(timestamp()) launch pid \(getpid()) \(buildInfo())\n")

        NSSetUncaughtExceptionHandler { CrashLog.logException($0) }
        for sig in fatalSignals {
            signal(sig, fatalSignalHandler)
        }
        signal(SIGTERM, termSignalHandler)
    }

    /// Call from `applicationWillTerminate` so the next launch knows this
    /// session ended on purpose.
    static func markCleanExit() {
        append("==== \(timestamp()) exit clean pid \(getpid()) uptime \(uptimeString())\n")
        try? FileManager.default.removeItem(at: sessionURL)
    }

    // MARK: - Normal-context logging

    private static func logException(_ exception: NSException) {
        exceptionLogged = true
        var text = "\n==== \(timestamp()) UNCAUGHT EXCEPTION pid \(getpid()) uptime \(uptimeString())\n"
        text += "\(exception.name.rawValue): \(exception.reason ?? "(no reason)")\n"
        text += exception.callStackSymbols.joined(separator: "\n")
        text += "\n"
        append(text)
    }

    private static func notePreviousSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let prev = try? JSONDecoder().decode(SessionMarker.self, from: data) else { return }
        let started = Date(timeIntervalSince1970: prev.startedAt)
        var line = "==== \(timestamp()) previous session pid \(prev.pid) (launched \(timestamp(started))) did not exit cleanly"
        if let report = newestCrashReport(after: started) {
            line += "; macOS crash report: \(report.path)"
        } else {
            line += "; no macOS crash report found (killed with SIGKILL, logout, or power loss)"
        }
        append(line + "\n")
    }

    private static func writeSessionMarker() {
        let marker = SessionMarker(pid: getpid(), startedAt: sessionStart.timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(marker) {
            try? data.write(to: sessionURL)
        }
    }

    private static func newestCrashReport(after date: Date) -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        return files
            .filter { $0.lastPathComponent.hasPrefix("VoicePaste-") && $0.pathExtension == "ips" }
            .compactMap { url -> (URL, Date)? in
                guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      m > date else { return nil }
                return (url, m)
            }
            .max { $0.1 < $1.1 }?
            .0
    }

    private static func buildInfo() -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        var built = "?"
        if let exe = Bundle.main.executableURL,
           let m = try? exe.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            built = timestamp(m)
        }
        return "version \(version) binary-built \(built)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    private static func timestamp(_ date: Date = Date()) -> String {
        dateFormatter.string(from: date)
    }

    private static func uptimeString() -> String {
        String(format: "%.0fs", Date().timeIntervalSince(sessionStart))
    }

    private static func append(_ text: String) {
        guard fd >= 0, let data = text.data(using: .utf8) else { return }
        data.withUnsafeBytes { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }

    // MARK: - Signal handlers (async-signal-safe only)

    private static let fatalSignalHandler: @convention(c) (Int32) -> Void = { sig in
        CrashLog.writeRaw("\n==== FATAL SIGNAL ")
        CrashLog.writeRaw(CrashLog.signalName(sig))
        CrashLog.writeRaw(" pid ")
        CrashLog.writeInt(Int(getpid()))
        CrashLog.writeRaw(" epoch ")
        CrashLog.writeInt(Int(time(nil)))
        CrashLog.writeRaw("\n")
        if CrashLog.exceptionLogged {
            CrashLog.writeRaw("(backtrace omitted: the uncaught exception above is the cause)\n")
        } else {
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 128) { buf in
                let n = backtrace(buf.baseAddress, 128)
                backtrace_symbols_fd(buf.baseAddress, n, CrashLog.fd)
            }
        }
        CrashLog.writeRaw("(macOS report: ~/Library/Logs/DiagnosticReports/VoicePaste-*.ips)\n")
        // Restore the default action and re-raise so macOS still writes its
        // own report and launchd sees a signal death (and restarts us).
        signal(sig, SIG_DFL)
        raise(sig)
    }

    private static let termSignalHandler: @convention(c) (Int32) -> Void = { _ in
        CrashLog.writeRaw("\n==== SIGTERM pid ")
        CrashLog.writeInt(Int(getpid()))
        CrashLog.writeRaw(" epoch ")
        CrashLog.writeInt(Int(time(nil)))
        CrashLog.writeRaw(" exit clean (terminated by launchd or kill)\n")
        if let path = CrashLog.sessionPathC {
            unlink(path)
        }
        _exit(0)
    }

    private static func signalName(_ sig: Int32) -> StaticString {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        default: return "UNKNOWN"
        }
    }

    private static func writeRaw(_ s: StaticString) {
        s.withUTF8Buffer { buf in
            _ = write(fd, buf.baseAddress, buf.count)
        }
    }

    private static func writeInt(_ value: Int) {
        withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 24) { buf in
            var v = value.magnitude
            var i = buf.count
            repeat {
                i -= 1
                buf[i] = UInt8(48 + v % 10)
                v /= 10
            } while v > 0
            if value < 0 {
                i -= 1
                buf[i] = 45  // '-'
            }
            _ = write(fd, buf.baseAddress! + i, buf.count - i)
        }
    }
}
