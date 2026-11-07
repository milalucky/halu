import Darwin
import IOKit.ps
import SwiftUI

/// The Mac's vitals, measured only while the System tab is open: processor, memory, disk,
/// battery, and the busiest apps.
@MainActor
final class SystemMonitor: ObservableObject {
    struct Process: Identifiable, Equatable {
        var id: Int32 { pid }
        var pid: Int32
        var name: String
        var cpu: Double
        var memory: Double
    }

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memoryUsed: Double = 0
    @Published private(set) var diskFree: Double = 0
    @Published private(set) var diskTotal: Double = 0
    @Published private(set) var battery: (level: Int, charging: Bool, minutes: Int?)?
    @Published private(set) var top: [Process] = []
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory)

    private var lastTicks: (busy: UInt64, total: UInt64)?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        sample()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        if let ticks = Self.cpuTicks() {
            if let last = lastTicks, ticks.total > last.total {
                cpu = Double(ticks.busy - last.busy) / Double(ticks.total - last.total)
                cpuHistory = Array((cpuHistory + [cpu]).suffix(60))
            }
            lastTicks = ticks
        }
        memoryUsed = Self.memoryUsed()
        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
            diskTotal = Double(values.volumeTotalCapacity ?? 0)
        }
        battery = Self.battery()
        DispatchQueue.global(qos: .utility).async {
            let top = Self.topProcesses()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.top = top } }
        }
    }

    private nonisolated static func cpuTicks() -> (busy: UInt64, total: UInt64)? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + idle + nice)
    }

    /// App memory, wired and compressed pages: what Activity Monitor calls "Memory Used".
    private nonisolated static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        let app = Double(stats.internal_page_count) - Double(stats.purgeable_count)
        return (app + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    private nonisolated static func battery() -> (Int, Bool, Int?)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let level = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let minutes = (description[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int).flatMap { $0 > 0 ? $0 : nil }
            return (level, charging, minutes)
        }
        return nil
    }

    /// The six busiest processes by processor, from `ps`.
    private nonisolated static func topProcesses() -> [Process] {
        let task = Foundation.Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm=", "-r"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return [] }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        task.waitUntilExit()
        return text.split(separator: "\n").prefix(6).compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { return nil }
            return Process(pid: pid, name: String(parts[3]), cpu: cpu, memory: rss * 1024)
        }
    }
}

struct SystemView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Gauge(title: "Processor", value: monitor.cpu, detail: "\(Int(monitor.cpu * 100))%", tint: Theme.accent, history: monitor.cpuHistory)
                Gauge(title: "Memory", value: monitor.memoryUsed / max(monitor.memoryTotal, 1),
                      detail: "\(bytes(monitor.memoryUsed)) of \(bytes(monitor.memoryTotal))", tint: Theme.blue, history: nil)
                Gauge(title: "Disk", value: 1 - monitor.diskFree / max(monitor.diskTotal, 1),
                      detail: "\(bytes(monitor.diskFree)) free", tint: Theme.orange, history: nil)
                if let battery = monitor.battery {
                    Gauge(title: battery.charging ? "Charging" : "Battery", value: Double(battery.level) / 100,
                          detail: "\(battery.level)%" + (battery.minutes.map { " · \($0 / 60)h \($0 % 60)m" } ?? ""),
                          tint: battery.level <= 20 && !battery.charging ? Theme.red : Theme.green, history: nil)
                }
            }
            // Cards share the tallest one's height (the processor's carries a history line).
            .fixedSize(horizontal: false, vertical: true)
            SmallCaps("Busiest right now")
            VStack(spacing: 2) {
                ForEach(monitor.top) { process in
                    HStack(spacing: 10) {
                        Text(process.name).font(Theme.body(12.5, weight: .medium)).foregroundStyle(Theme.primary).lineLimit(1)
                        Spacer()
                        Text(bytes(process.memory)).font(Theme.caption(11.5, weight: .medium)).monospacedDigit().foregroundStyle(Theme.tertiary)
                            .frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.0f%%", process.cpu)).font(Theme.caption(12, weight: .bold)).monospacedDigit()
                            .foregroundStyle(process.cpu > 80 ? Theme.red : process.cpu > 30 ? Theme.orange : Theme.secondary)
                            .frame(width: 48, alignment: .trailing)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.card))
                }
            }
            .animation(.easeOut(duration: 0.3), value: monitor.top)
            Spacer(minLength: 0)
        }
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
    }

    private func bytes(_ value: Double) -> String { ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory) }
}

/// A ring with the reading in the middle; the processor also gets a small line of the last two minutes.
private struct Gauge: View {
    let title: String
    let value: Double
    let detail: String
    let tint: Color
    let history: [Double]?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().stroke(Theme.card, lineWidth: 8)
                Circle().trim(from: 0, to: min(1, max(0, value)))
                    .stroke(AngularGradient(colors: [tint.opacity(0.6), tint], center: .center), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.6, dampingFraction: 0.8), value: value)
                Text("\(Int(value * 100))%").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(Theme.primary)
                    .contentTransition(.numericText())
            }
            .frame(width: 74, height: 74)
            Text(title.uppercased()).font(Theme.caption(9.5, weight: .bold)).tracking(0.5).foregroundStyle(tint)
            Text(detail).font(Theme.caption(10.5, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1).minimumScaleFactor(0.7)
            if let history, history.count > 1 {
                Path { path in
                    for (index, point) in history.enumerated() {
                        let x = 100 * CGFloat(index) / CGFloat(max(history.count - 1, 1)), y = 18 * (1 - CGFloat(point))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(tint, lineWidth: 1.2)
                .frame(width: 100, height: 18)
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .glass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: tint.opacity(0.25))
    }
}
