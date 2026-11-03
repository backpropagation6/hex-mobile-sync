import Darwin.Mach
import Foundation
import os
import UIKit

/// A small local log of dictation start-up events (never dictated text), to
/// debug the Action Button path on a device. Kept in Application Support,
/// excluded from backups, trimmed to the last ``maxLines`` lines.
enum Diagnostics {
    /// The log pulled from the device on 1 Nov 2026 was full at 200 lines
    /// (16 KB, covering only 28 minutes), and the retry loop now adds a line
    /// per failed audio attempt. Each record rewrites the whole file; at 1000
    /// lines that is about 80 KB (extrapolated from that log), acceptable
    /// because the app logs events, not audio buffers.
    static let maxLines = 1000

    static var file: URL { AppPaths.applicationSupport.appending(path: "diagnostics.log") }

    /// When this process started, from the kernel (`p_starttime`), not from
    /// the first access: a plain `static let` would only capture the moment
    /// of the first log line.
    static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()

    /// Seconds since the process was launched, with one decimal.
    static var secondsSinceLaunch: String {
        String(format: "%.1f", Date().timeIntervalSince(processStart))
    }

    /// Resident memory the system charges this process for, in MB
    /// (`phys_footprint` from `TASK_VM_INFO`, the figure jetsam compares with
    /// the limit), or `?` when the kernel refuses.
    static var footprintMB: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.0f", Double(info.phys_footprint) / 1_048_576)
    }

    /// The most `phys_footprint` this process has reached since it started, in
    /// MB (`ledger_phys_footprint_peak`), or `?`. What a model load or run
    /// costs at its worst, which the current footprint (read after the work)
    /// does not show.
    static var peakFootprintMB: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.0f", Double(info.ledger_phys_footprint_peak) / 1_048_576)
    }

    /// `footprint=212MB available=1650MB bgTime=-`: memory in use, memory left
    /// before the per-process limit (`os_proc_available_memory`), and the
    /// background time the system still grants (`-` in the foreground;
    /// `unlimited` when `backgroundTimeRemaining` is the huge value the
    /// system reports for an app with no time limit).
    @MainActor
    static func processSummary() -> String {
        #if targetEnvironment(simulator)
        let available = "n/a" // the simulator reported 0 (1 Nov 2026)
        #else
        let available = String(format: "%.0fMB", Double(os_proc_available_memory()) / 1_048_576)
        #endif
        let application = UIApplication.shared
        let background: String
        if application.applicationState == .background {
            let remaining = application.backgroundTimeRemaining
            background = remaining > 100_000 ? "unlimited" : String(format: "%.0fs", remaining)
        } else {
            background = "-"
        }
        return "footprint=\(footprintMB)MB available=\(available) bgTime=\(background)"
    }

    @MainActor private static var isObservingLifecycle = false

    /// Logs the app and scene lifecycle and memory warnings: when the process
    /// is killed or suspended while the microphone is on, the last lines of
    /// the log say which of these came last (a jetsam kill sends nothing).
    /// The observers run synchronously on the posting thread, so
    /// `willTerminate` is written before the process goes. No background
    /// task exists in the app (nothing calls `beginBackgroundTask`), so none
    /// can expire.
    @MainActor
    static func observeLifecycle() {
        guard !isObservingLifecycle else { return }
        isObservingLifecycle = true
        let events: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "app didBecomeActive"),
            (UIApplication.willResignActiveNotification, "app willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "app didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "app willEnterForeground"),
            (UIApplication.didReceiveMemoryWarningNotification, "app didReceiveMemoryWarning"),
            (UIApplication.willTerminateNotification, "app willTerminate"),
            (UIScene.willConnectNotification, "scene willConnect"),
            (UIScene.didDisconnectNotification, "scene didDisconnect"),
        ]
        for (name, label) in events {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { record("lifecycle \(label) \(processSummary())") }
                } else {
                    Task { @MainActor in record("lifecycle \(label) \(processSummary())") }
                }
            }
        }
        // One line per process: a kill shows as a new start in the log.
        record("lifecycle process started pid=\(getpid()) t=\(secondsSinceLaunch)s \(processSummary())")
    }

    @MainActor
    static func record(_ message: String) {
        let state: String = switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
        let line = "\(Date().ISO8601Format()) [\(state)] \(message)\n"
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(contentsOf: line.split(separator: "\n").map(String.init))
        let text = lines.suffix(maxLines).joined(separator: "\n") + "\n"
        try? text.write(to: file, atomically: true, encoding: .utf8)
    }
}
