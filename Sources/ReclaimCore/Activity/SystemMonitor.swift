import Foundation
import Darwin

// MARK: - Models

/// One running process, as seen by a non-privileged read of the process table.
/// CPU is a recent utilization percentage (100% = one core fully busy); memory
/// is resident size. Read-only — sampling never touches a process.
public struct RunningProcess: Identifiable, Sendable, Hashable {
    public let pid: Int32
    public let name: String        // friendly command name (basename)
    public let path: String        // full executable path (for app matching)
    public let cpuPercent: Double
    public let memoryBytes: Int64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, path: String, cpuPercent: Double, memoryBytes: Int64) {
        self.pid = pid; self.name = name; self.path = path
        self.cpuPercent = cpuPercent; self.memoryBytes = memoryBytes
    }
}

/// How hot the Mac is running — mirrors `ProcessInfo.ThermalState` but stays
/// Sendable and independent of AppKit so it lives in ReclaimCore.
public enum ThermalLevel: String, Sendable { case nominal, fair, serious, critical }

/// A single, whole-machine health snapshot. Every number is readable without
/// root on a Developer-ID (non-sandboxed) app.
public struct SystemHealth: Sendable {
    public let sampledAt: Date
    // CPU
    public let loadAverage1: Double
    public let coreCount: Int
    // Memory
    public let totalMemoryBytes: Int64
    public let usedMemoryBytes: Int64      // active + wired + compressed
    public let wiredBytes: Int64
    public let compressedBytes: Int64
    public let appBytes: Int64             // active + inactive (roughly app memory)
    public let freeMemoryBytes: Int64
    public let swapUsedBytes: Int64
    public let swapTotalBytes: Int64
    // Thermal / uptime
    public let thermal: ThermalLevel
    public let uptimeSeconds: Double
    // Disk (startup volume)
    public let freeDiskBytes: Int64
    public let totalDiskBytes: Int64
    // Startup
    public let loginItemsCount: Int
    // Processes (all, unsorted; the UI slices top-by-cpu / top-by-memory)
    public let processes: [RunningProcess]

    public var memoryUsedFraction: Double {
        totalMemoryBytes > 0 ? Double(usedMemoryBytes) / Double(totalMemoryBytes) : 0
    }
    public var diskUsedFraction: Double {
        totalDiskBytes > 0 ? Double(totalDiskBytes - freeDiskBytes) / Double(totalDiskBytes) : 0
    }
}

/// A plain-language reason the Mac might feel slow, ranked by severity. Advisory
/// only — Reclaim explains, it never silently "optimizes".
public struct Diagnosis: Identifiable, Sendable {
    public enum Severity: Int, Sendable, Comparable {
        case ok = 0, info = 1, warning = 2, critical = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let id: String
    public let severity: Severity
    public let title: String
    public let detail: String
    public let symbol: String
    /// True when the fix lives in Reclaim's own storage cleanup (low disk).
    public let reclaimActionable: Bool

    public init(id: String, severity: Severity, title: String, detail: String,
                symbol: String, reclaimActionable: Bool = false) {
        self.id = id; self.severity = severity; self.title = title
        self.detail = detail; self.symbol = symbol; self.reclaimActionable = reclaimActionable
    }
}

// MARK: - Monitor

/// Read-only system health + process sampler. Uses only APIs a non-sandboxed
/// Developer-ID app can call without elevated privileges: `sysctl`, mach host
/// statistics, `getloadavg`, and the process table via `ps`.
public struct SystemMonitor: Sendable {
    public init() {}

    public func sample() -> SystemHealth {
        let mem = Self.memoryStats()
        let swap = Self.swapUsage()
        let disk = VolumeProbe.dataVolume()
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)

        return SystemHealth(
            sampledAt: Date(),
            loadAverage1: load[0],
            coreCount: ProcessInfo.processInfo.activeProcessorCount,
            totalMemoryBytes: Self.physicalMemory(),
            usedMemoryBytes: mem.wired + mem.compressed + mem.active,
            wiredBytes: mem.wired,
            compressedBytes: mem.compressed,
            appBytes: mem.active + mem.inactive,
            freeMemoryBytes: mem.free,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            thermal: Self.thermalLevel(),
            uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            freeDiskBytes: disk.free,
            totalDiskBytes: disk.total,
            loginItemsCount: Self.loginItemsCount(),
            processes: Self.processList())
    }

    /// Turn a snapshot into ranked, plain-language "why it's slow" findings.
    public func diagnose(_ h: SystemHealth) -> [Diagnosis] {
        var out: [Diagnosis] = []

        // Low disk — a top, and Reclaim-fixable, cause of slowness.
        let diskFree = h.diskUsedFraction
        if h.totalDiskBytes > 0 && (diskFree >= 0.97 || h.freeDiskBytes < 5 * 1024 * 1024 * 1024) {
            out.append(Diagnosis(
                id: "disk", severity: diskFree >= 0.98 ? .critical : .warning,
                title: "Your startup disk is almost full",
                detail: "Only \(ByteFormatter.string(h.freeDiskBytes)) free. macOS needs headroom for swap and caching — a nearly-full disk makes everything feel slow. Reclaim can free space safely.",
                symbol: "internaldrive", reclaimActionable: true))
        } else if h.totalDiskBytes > 0 && diskFree >= 0.90 {
            out.append(Diagnosis(
                id: "disk", severity: .info,
                title: "Your disk is filling up",
                detail: "\(Int(diskFree * 100))% full, \(ByteFormatter.string(h.freeDiskBytes)) free. Worth reclaiming space before it gets tight.",
                symbol: "internaldrive", reclaimActionable: true))
        }

        // Memory pressure / swap thrash.
        if h.swapUsedBytes > 3 * 1024 * 1024 * 1024 || (h.memoryUsedFraction > 0.9 && h.swapUsedBytes > 1024 * 1024 * 1024) {
            out.append(Diagnosis(
                id: "memory", severity: h.swapUsedBytes > 6 * 1024 * 1024 * 1024 ? .critical : .warning,
                title: "Your Mac is low on memory",
                detail: "It's overflowing \(ByteFormatter.string(h.swapUsedBytes)) onto the disk as swap, which is much slower than RAM. Quitting memory-heavy apps below will help most.",
                symbol: "memorychip"))
        } else if h.memoryUsedFraction > 0.85 {
            out.append(Diagnosis(
                id: "memory", severity: .info,
                title: "Memory is heavily used",
                detail: "Apps are using \(Int(h.memoryUsedFraction * 100))% of your RAM. Fine for now, but closing what you're not using frees it up.",
                symbol: "memorychip"))
        }

        // CPU load vs cores.
        if h.coreCount > 0 && h.loadAverage1 > Double(h.coreCount) * 1.5 {
            out.append(Diagnosis(
                id: "cpu", severity: h.loadAverage1 > Double(h.coreCount) * 2.5 ? .warning : .info,
                title: "Your Mac is working hard",
                detail: "There's more work queued than your \(h.coreCount) cores can handle at once. See what's using the CPU below.",
                symbol: "cpu"))
        }

        // Thermal throttling.
        if h.thermal == .serious || h.thermal == .critical {
            out.append(Diagnosis(
                id: "thermal", severity: h.thermal == .critical ? .critical : .warning,
                title: "Your Mac is running hot",
                detail: "It's slowing itself down to cool off (thermal throttling). A heavy app, or blocked vents, is usually the cause. Give it a moment or close demanding apps.",
                symbol: "thermometer.high"))
        }

        // Runaway single process.
        if let hog = h.processes.max(by: { $0.cpuPercent < $1.cpuPercent }), hog.cpuPercent > 90 {
            out.append(Diagnosis(
                id: "hog-cpu", severity: .info,
                title: "\(hog.name) is using a lot of CPU",
                detail: "\(hog.name) is at \(Int(hog.cpuPercent))% CPU right now. If that's unexpected, quitting it should speed things up.",
                symbol: "bolt"))
        }

        // Startup bloat.
        if h.loginItemsCount >= 20 {
            out.append(Diagnosis(
                id: "login", severity: .info,
                title: "A lot of items launch at startup",
                detail: "\(h.loginItemsCount) background/login items start with your Mac, slowing boot and running in the background. Review them in System Settings → General → Login Items.",
                symbol: "power"))
        }

        if out.isEmpty {
            out.append(Diagnosis(
                id: "ok", severity: .ok,
                title: "Your Mac looks healthy",
                detail: "Nothing is obviously slowing it down right now — memory, CPU, temperature, and disk all look fine.",
                symbol: "checkmark.seal"))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    // MARK: - Sysctl / mach helpers

    private static func physicalMemory() -> Int64 {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.stride
        return sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 ? value : Int64(ProcessInfo.processInfo.physicalMemory)
    }

    private static func swapUsage() -> (used: Int64, total: Int64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.stride
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    private static func memoryStats() -> (free: Int64, active: Int64, inactive: Int64, wired: Int64, compressed: Int64) {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0, 0, 0, 0) }
        let page = Int64(getpagesize())
        return (Int64(stats.free_count) * page,
                Int64(stats.active_count) * page,
                Int64(stats.inactive_count) * page,
                Int64(stats.wire_count) * page,
                Int64(stats.compressor_page_count) * page)
    }

    private static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }

    /// Count of user + system LaunchAgents — a reasonable proxy for "things that
    /// start with your Mac" without needing private login-item APIs.
    private static func loginItemsCount() -> Int {
        let dirs = [
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents"),
            "/Library/LaunchAgents",
        ]
        var count = 0
        for dir in dirs {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            count += entries.filter { $0.hasSuffix(".plist") }.count
        }
        return count
    }

    // MARK: - Process table (via ps — works for all processes, no root)

    private static func processList() -> [RunningProcess] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        // pid, recent %cpu, resident set size (KB), full command path.
        task.arguments = ["-axo", "pid=,%cpu=,rss=,comm="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let me = ProcessInfo.processInfo.processIdentifier
        var out: [RunningProcess] = []
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4,
                  let pid = Int32(fields[0]), pid != me,
                  let cpu = Double(fields[1]),
                  let rssKB = Int64(fields[2]) else { continue }
            let path = fields[3...].joined(separator: " ")
            let name = Self.friendlyName(path)
            out.append(RunningProcess(pid: pid, name: name, path: path,
                                      cpuPercent: cpu, memoryBytes: rssKB * 1024))
        }
        return out
    }

    /// A human name from an executable path: the app bundle name if it's inside
    /// one ("…/Google Chrome.app/…/Google Chrome" → "Google Chrome"), else the
    /// binary's basename.
    static func friendlyName(_ path: String) -> String {
        if let r = path.range(of: ".app/") {
            let bundle = String(path[..<r.lowerBound])
            return (bundle as NSString).lastPathComponent
        }
        return (path as NSString).lastPathComponent
    }
}
