import Foundation

/// Time since the Mac started, sleep included — what `uptime`, Activity Monitor, and
/// System Information report.
///
/// `ProcessInfo.systemUptime` is the time the Mac has been *awake*: it stops while the
/// Mac sleeps, so on a laptop that sleeps every night it falls days behind every other
/// tool. The dashboard's Device card and the CPU detail both read this instead.
enum SystemUptime {
    /// When the Mac started, from `kern.boottime`. Read once, so a view showing the
    /// uptime never makes a system call as it redraws.
    static let bootDate: Date? = {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, u_int(mib.count), &bootTime, &size, nil, 0) == 0,
              bootTime.tv_sec > 0
        else { return nil }
        return Date(
            timeIntervalSince1970: TimeInterval(bootTime.tv_sec)
                + TimeInterval(bootTime.tv_usec) / 1_000_000
        )
    }()

    /// Seconds since the Mac started. Falls back to the awake time only when the boot
    /// time cannot be read.
    static var sinceBoot: TimeInterval {
        guard let bootDate else { return ProcessInfo.processInfo.systemUptime }
        return max(Date().timeIntervalSince(bootDate), 0)
    }
}
