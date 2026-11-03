import Darwin.Mach
import Foundation
import os
import Synchronization

/// Local log of keyboard events (never text), in the keyboard's own
/// container, to debug insertion on a device. Last 200 lines.
enum KeyboardDiagnostics {
    static var file: URL {
        let dir = URL.libraryDirectory.appending(path: "Application Support")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "keyboard-diagnostics.log")
    }

    static func record(_ message: String) {
        let line = "\(Date().ISO8601Format()) \(message)"
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
        lines.append(line)
        try? (lines.suffix(200).joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: - Process and memory

    /// Why this exists (1 Nov 2026): the phone had three `HexKeyboard`
    /// crashes (SIGABRT) and then none, while the keyboard still dropped back
    /// to the previous one. iOS is said to end a keyboard that goes over its
    /// memory limit (about 60 MB of `phys_footprint`, reported by other
    /// developers, not measured here) without a crash log. A `process started`
    /// line with no crash report before it means the process was ended, not
    /// that it crashed; the footprint on `appear`, `disappear` and on a memory
    /// warning shows how close it was.

    /// Resident memory the system charges this process for, in MB
    /// (`phys_footprint` from `TASK_VM_INFO`, the figure the limit is
    /// compared with), or `?` when the kernel refuses. Same reading as the
    /// app's `Diagnostics.footprintMB`.
    static var footprintMB: String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return "?" }
        return String(format: "%.1f", Double(info.phys_footprint) / 1_048_576)
    }

    /// Keyboard controllers alive in this process. A keyboard that iOS drops
    /// without `viewDidDisappear` (a host app that was killed) used to leave
    /// its SwiftUI graph and model alive; see `KeyboardViewController.deinit`
    /// and docs/ARCHITECTURE.md, "Keyboard memory leak".
    private static let liveControllers = Mutex(0)

    static func controllerLoaded() { liveControllers.withLock { $0 += 1 } }
    /// `unshown`: the controller was loaded and never appeared (iOS dropped it
    /// before showing it; the line then ends with `unshown`).
    static func controllerDeallocated(unshown: Bool = false) {
        let left = liveControllers.withLock { value -> Int in
            value -= 1
            return value
        }
        record("keyboard controller deinit controllers=\(left) models=\(liveModels.withLock { $0 })\(unshown ? " unshown" : "")")
    }

    /// Keyboard models alive in this process. The device log of 1 Nov 2026
    /// showed no `keyboard model deinit` at all and, after twenty sessions,
    /// every signal three times: models outlived their controllers. A healthy
    /// process has `models` equal to `controllers` (one per keyboard on
    /// screen, plus at most the one iOS is still releasing).
    private static let liveModels = Mutex(0)

    static func modelCreated() { liveModels.withLock { $0 += 1 } }
    static func modelDeallocated() {
        let left = liveModels.withLock { value -> Int in
            value -= 1
            return value
        }
        record("keyboard model deinit models=\(left)")
    }

    /// `footprint=21.4MB available=38MB controllers=1 models=1`: memory in
    /// use, what is left before the per-process limit
    /// (`os_proc_available_memory`; the simulator reports 0, so `n/a` there),
    /// the controllers alive and the models alive.
    static var memorySummary: String {
        #if targetEnvironment(simulator)
        let available = "n/a"
        #else
        let available = "\(os_proc_available_memory() / 1_048_576)MB"
        #endif
        return "footprint=\(footprintMB)MB available=\(available) controllers=\(liveControllers.withLock { $0 }) models=\(liveModels.withLock { $0 })"
    }

    /// When this process started, from the kernel (`p_starttime`).
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return Date() }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return Date() }
        return Date(timeIntervalSince1970: TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000)
    }()

    /// Written once per process, by whichever call reaches it first.
    private static let processStartLogged: Bool = {
        record("keyboard process started pid=\(getpid()) kernelStart=\(processStart.ISO8601Format()) "
            + "age=\(String(format: "%.2f", Date().timeIntervalSince(processStart)))s \(memorySummary)")
        return true
    }()

    /// Logs `keyboard process started pid=…` the first time it is called in
    /// this process (the first controller's `viewDidLoad`), and does nothing
    /// afterwards.
    static func noteProcessStart() {
        _ = processStartLogged
    }
}
