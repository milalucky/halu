import SwiftUI

/// VPN switcher next to Keep Awake: a click lists every server of every VPN, grouped by app; picking
/// one switches to it (whatever was on goes off). The shield fills green while a tunnel is up.
struct VPNButton: View {
    @ObservedObject var vpn: VPNController
    @State private var hovering = false

    var body: some View {
        if !vpn.connections.isEmpty || !vpn.apps.isEmpty {
            let active = vpn.connections.first { $0.state != .off }
            let tint = vpn.isOn ? Theme.green : vpn.isConnecting ? Theme.orange : (hovering ? Theme.secondary : Theme.tertiary)
            Menu {
                menu(active)
            } label: {
                // Icon only: the header wing is narrow. The server's name is in the tooltip and the menu.
                Image(systemName: vpn.isOn ? "lock.shield.fill" : "lock.shield")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: vpn.isConnecting)
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 22)
                    .background(Capsule().fill(active != nil ? tint.opacity(0.15) : (hovering ? Theme.card : .clear)))
                    .contentShape(Capsule())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .help(help(active))
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: active?.id)
            .onAppear(perform: vpn.refresh)
        }
    }

    @ViewBuilder
    private func menu(_ active: VPNController.Connection?) -> some View {
        if let active {
            Button("Turn off \(active.name)") { vpn.set(active, on: false) }
            Divider()
        }
        ForEach(providers, id: \.self) { provider in
            Section(provider) {
                ForEach(vpn.connections.filter { $0.provider == provider }) { connection in
                    Button {
                        if connection.state == .off { vpn.set(connection, on: true) }
                    } label: {
                        if connection.state == .on {
                            Label(connection.name, systemImage: "checkmark")
                        } else if connection.state == .connecting {
                            Label(connection.name + " · connecting", systemImage: "ellipsis")
                        } else {
                            Text(connection.name)
                        }
                    }
                }
            }
        }
        if !vpn.apps.isEmpty {
            Divider()
            ForEach(vpn.apps) { app in
                Button("Open \(app.name)") { vpn.open(app) }
            }
        }
    }

    private var providers: [String] {
        var seen: [String] = []
        for connection in vpn.connections where !seen.contains(connection.provider) { seen.append(connection.provider) }
        return seen
    }

    private func help(_ active: VPNController.Connection?) -> String {
        if let active { return "\(active.name) is on · click to switch or turn off" }
        return "VPN · choose a server"
    }
}
