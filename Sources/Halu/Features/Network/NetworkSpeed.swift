import Darwin
import SwiftUI

/// Live download and upload speed of the Mac, from the byte counters of its network interfaces.
/// With a VPN on, macOS may count the traffic only on the tunnel (utun), so the busier of the two
/// groups — physical ports or tunnels — is shown, never their sum, so nothing is counted twice.
@MainActor
final class NetworkSpeed: ObservableObject {
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0

    private var last: (counters: [String: (UInt64, UInt64)], at: Date)?
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
        let counters = Self.counters()
        if let last {
            let seconds = now.timeIntervalSince(last.at)
            var ports: (Double, Double) = (0, 0), tunnels: (Double, Double) = (0, 0)
            for (name, value) in counters {
                guard let old = last.counters[name], value.0 >= old.0, value.1 >= old.1 else { continue }
                let delta = (Double(value.0 - old.0) / seconds, Double(value.1 - old.1) / seconds)
                if name.hasPrefix("utun") {
                    tunnels = (tunnels.0 + delta.0, tunnels.1 + delta.1)
                } else {
                    ports = (ports.0 + delta.0, ports.1 + delta.1)
                }
            }
            down = max(ports.0, tunnels.0)
            up = max(ports.1, tunnels.1)
        }
        last = (counters, now)
    }

    /// Bytes received and sent per interface: Wi-Fi/Ethernet ports (en) and VPN tunnels (utun).
    private nonisolated static func counters() -> [String: (UInt64, UInt64)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [:] }
        defer { freeifaddrs(list) }
        var result: [String: (UInt64, UInt64)] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("utun") else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            result[name] = (UInt64(stats.ifi_ibytes), UInt64(stats.ifi_obytes))
        }
        return result
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
        // A steady width, so the buttons beside it don't jump as the number changes.
        .frame(width: 44, alignment: .trailing)
        .padding(.trailing, 4)
        .help("Download \(NetworkSpeed.long(speed.down)) · upload \(NetworkSpeed.long(speed.up))")
        .onAppear(perform: speed.start)
        .onDisappear(perform: speed.stop)
    }
}
