import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfView: View {
    @ObservedObject var store: ShelfStore

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Shelf", detail: store.items.isEmpty ? nil : "\(store.items.count) items",
                          trailing: store.items.isEmpty ? nil : AnyView(
                              Button("Clear") { withAnimation { store.clear() } }
                                  .buttonStyle(.plain)
                                  .font(Theme.caption(12, weight: .medium))
                                  .foregroundStyle(Theme.tertiary)
                          ))
            if !store.items.isEmpty {
                InputField(placeholder: "Search files and the text on screenshots", icon: "text.magnifyingglass", text: $store.query)
            }
            if store.items.isEmpty {
                EmptyState(icon: "tray.and.arrow.down", title: "Drop files here",
                           subtitle: "New screenshots and screen recordings appear here on their own. Drag them out wherever you need them.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.visible) { item in
                            ShelfCard(item: item, store: store)
                        }
                    }
                    .padding(.top, 2)
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct ShelfCard: View {
    let item: ShelfItem
    let store: ShelfStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Thumbnail(url: item.url)
                .frame(height: 70)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(hovering ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1)
                )
                .overlay(alignment: .bottomLeading) {
                    if item.kind == .video {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(5)
                            .background(Circle().fill(.black.opacity(0.6)))
                            .padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button { withAnimation { store.remove(item) } } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .black))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(.black.opacity(0.7)))
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                    }
                }
            Text(caption)
                .font(Theme.caption(10.5, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
        }
        .scaleEffect(hovering ? 1.03 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .onTapGesture(count: 2) { store.open(item) }
        .contextMenu {
            Button("Open") { store.open(item) }
            Button("Show in Finder") { store.reveal(item) }
            Button("Copy") { store.copy(item) }
            Divider()
            Button("Remove from Shelf", role: .destructive) { store.remove(item) }
        }
        .help(item.url.lastPathComponent)
    }

    private var caption: String {
        switch item.source {
        case .screenshot: "\(item.kind == .video ? "Recording" : "Screenshot") · \(Fmt.time.string(from: item.addedAt))"
        case .clipboard: "Clipboard · \(Fmt.time.string(from: item.addedAt))"
        case .dropped: item.url.lastPathComponent
        }
    }
}

private struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.card
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small).opacity(0.4)
            }
        }
        .task(id: url) { image = await ThumbnailCache.shared.image(for: url) }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    func image(for url: URL) async -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 140), scale: 2,
                                                   representationTypes: .thumbnail)
        let image: NSImage
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = representation.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
