import SwiftUI
import WebKit

struct ChatView: View {
    @ObservedObject var store: ChatStore

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text("ChatGPT").font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                if store.isLoading { ProgressView().controlSize(.mini) }
                Spacer()
                IconButton(icon: "chevron.left", help: "Back", action: store.goBack)
                IconButton(icon: "house", help: "New chat", action: store.goHome)
                IconButton(icon: "arrow.clockwise", help: "Reload", action: store.reload)
                IconButton(icon: "safari", help: "Open in your browser", action: store.openInBrowser)
            }
            WebViewHost(webView: store.webView)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline))
        }
    }
}

/// Puts the store's long-lived web view on screen without recreating it.
private struct WebViewHost: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if webView.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        webView.removeFromSuperview()
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // Typing goes to the page once it's shown.
        DispatchQueue.main.async {
            webView.window?.makeKey()
            webView.window?.makeFirstResponder(webView)
        }
    }
}

/// Header button: opens ChatGPT in the panel, and a second click goes back to the tab you were on.
struct ChatButton: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false
    @State private var previous: Tab?

    var body: some View {
        let on = model.tab == .chat
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                if on {
                    model.tab = previous ?? .tasks
                } else {
                    previous = model.tab
                    model.tab = .chat
                }
            }
        } label: {
            Image(systemName: on ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Theme.primary : (hovering ? Theme.secondary : Theme.tertiary))
                .headerButton(active: on, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(on ? "Back to \(previous?.title ?? "Tasks")" : "ChatGPT")
    }
}
