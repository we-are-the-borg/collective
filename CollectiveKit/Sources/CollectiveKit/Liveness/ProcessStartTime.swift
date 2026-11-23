import Foundation

/// Used to detect PID reuse: a process younger than a session's first event
/// cannot be that session's process.
public enum ProcessStartTime {
    /// When process `pid` started, or nil if no such process exists (or it can't be queried).
    public static func of(_ pid: Int32) -> Date? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }
}
