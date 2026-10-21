import Darwin
import SwiftUI

/// Live download and upload speed of the Mac, from the byte counters of its network ports. Tunnels
/// (utun, used by VPNs) and loopback are left out so traffic isn't counted twice.
@MainActor
final class NetworkSpeed: ObservableObject {
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0

    private var last: (received: UInt64, sent: UInt64, at: Date)?
    private var timer: Timer?

    /// Measures only while the header shows it.
    func start() {
        guard timer == nil else { return }
        last = nil
        sample()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func sample() {
        let now = Date()
        let (received, sent) = Self.counters()
        if let last, received >= last.received, sent >= last.sent {
            let seconds = now.timeIntervalSince(last.at)
            down = Double(received - last.received) / seconds
            up = Double(sent - last.sent) / seconds
        }
        last = (received, sent, now)
    }

    private nonisolated static func counters() -> (UInt64, UInt64) {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (0, 0) }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            received += UInt64(stats.ifi_ibytes)
            sent += UInt64(stats.ifi_obytes)
        }
        return (received, sent)
    }

    /// "2.1M", "340K", "0" — short enough for the header. Bytes per second.
    static func short(_ bytes: Double) -> String {
        switch bytes {
        case ..<1024: return "0"
        case ..<(1024 * 1024): return "\(Int(bytes / 1024))K"
        default: return String(format: bytes < 10 * 1024 * 1024 ? "%.1fM" : "%.0fM", bytes / 1024 / 1024)
        }
    }

    static func long(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) + "/s"
    }
}

struct SpeedLabel: View {
    @ObservedObject var speed: NetworkSpeed

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.down").font(.system(size: 8, weight: .bold))
            Text(NetworkSpeed.short(speed.down)).monospacedDigit()
        }
        .font(Theme.caption(11, weight: .semibold))
        .foregroundStyle(speed.down > 1024 * 100 ? Theme.secondary : Theme.tertiary)
        .lineLimit(1)
        .fixedSize()
        .help("Download \(NetworkSpeed.long(speed.down)) · upload \(NetworkSpeed.long(speed.up))")
        .onAppear(perform: speed.start)
        .onDisappear(perform: speed.stop)
    }
}
