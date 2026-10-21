import SwiftUI

struct CompareView: View {
    @ObservedObject var store: CompareStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Slot(input: store.left, side: "A", store: store, isLeft: true)
                IconButton(icon: "arrow.left.arrow.right", help: "Swap") { store.swap() }
                    .opacity(store.left != nil || store.right != nil ? 1 : 0.3)
                Slot(input: store.right, side: "B", store: store, isLeft: false)
            }
            if let problem = store.problem {
                Text(problem).font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.orange)
            }
            if let result = store.result {
                Toolbar(store: store, result: result)
                ResultView(result: result)
            } else {
                EmptyState(icon: "arrow.left.arrow.right.square", title: "Compare two things",
                           subtitle: "Drop two files, or paste text into A and B: JSON, PDF (text or filled-in fields), Word, Markdown, any text, or two images.")
            }
        }
    }
}

/// One side: what's loaded there, or a place to drop or paste it.
private struct Slot: View {
    let input: CompareStore.Input?
    let side: String
    @ObservedObject var store: CompareStore
    let isLeft: Bool
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 9) {
            Text(side)
                .font(Theme.caption(10, weight: .bold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Theme.card))
            if let input {
                Image(systemName: input.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(input.name).font(Theme.body(12.5, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1).truncationMode(.middle)
                    Text(input.detail).font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                IconButton(icon: "xmark", help: "Clear", size: 9) { store.clear(left: isLeft) }
            } else {
                Text("Drop a file").font(Theme.caption(11.5, weight: .regular)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 4)
                SmallButton(title: "Paste") { store.paste(intoLeft: isLeft) }
                SmallButton(title: "Open…") { store.choose(intoLeft: isLeft) }
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: 46)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(targeted ? Theme.cardHover : Theme.card))
        .overlay {
            if input == nil || targeted {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(targeted ? Theme.accent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            store.load(providers: providers, into: providers.count > 1 ? nil : isLeft)
            return true
        }
        .contextMenu {
            Button("Paste") { store.paste(intoLeft: isLeft) }
            Button("Open…") { store.choose(intoLeft: isLeft) }
            if input != nil { Button("Clear") { store.clear(left: isLeft) } }
        }
    }
}

private struct SmallButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.caption(11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.primary : Theme.secondary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(hovering ? Theme.cardHover : Color.white.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Mode, text options and the summary of what differs.
private struct Toolbar: View {
    @ObservedObject var store: CompareStore
    let result: CompareStore.Result

    var body: some View {
        HStack(spacing: 10) {
            if store.canCompareStructure {
                Picker("", selection: $store.mode) {
                    ForEach(CompareStore.Mode.allCases) { Text(label($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if case .lines = result {
                Toggle("Ignore spaces", isOn: $store.options.ignoreWhitespace)
                Toggle("Ignore case", isOn: $store.options.ignoreCase)
            }
            Spacer()
            Text(summary)
                .font(Theme.caption(11.5, weight: .semibold))
                .foregroundStyle(isSame ? Theme.green : Theme.secondary)
        }
        .toggleStyle(.checkbox)
        .font(Theme.caption(11.5, weight: .medium))
        .foregroundStyle(Theme.secondary)
        .controlSize(.small)
    }

    private func label(_ mode: CompareStore.Mode) -> String {
        guard mode == .structure else { return "Text" }
        return store.left?.kind == .pdf ? "Fields" : "JSON"
    }

    private var isSame: Bool {
        switch result {
        case .lines(let lines): !lines.contains { $0.kind != .same }
        case .changes(let changes): changes.isEmpty
        case .image(let image): image.differing == 0 && image.sizes.0 == image.sizes.1
        case .problem: false
        }
    }

    private var summary: String {
        if isSame { return "Identical" }
        switch result {
        case .lines(let lines):
            let added = lines.filter { $0.kind == .added }.count, removed = lines.filter { $0.kind == .removed }.count
            return "−\(removed) · +\(added) lines"
        case .changes(let changes):
            let count = { (kind: Diff.Change.Kind) in changes.filter { $0.kind == kind }.count }
            return [(count(.changed), "changed"), (count(.added), "added"), (count(.removed), "removed")]
                .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        case .image(let image):
            let percent = image.differing * 100
            return (percent < 0.1 && percent > 0 ? "<0.1" : String(format: "%.1f", percent)) + "% of pixels differ"
        case .problem:
            return ""
        }
    }
}

private struct ResultView: View {
    let result: CompareStore.Result

    var body: some View {
        switch result {
        case .lines(let lines): TextDiffView(lines: lines)
        case .changes(let changes): ChangesView(changes: changes)
        case .image(let image): ImageDiffView(result: image)
        case .problem(let message):
            Text(message).font(Theme.body(12.5)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: Text

private struct TextDiffView: View {
    let lines: [Diff.Line]
    /// Runs of unchanged lines the user opened up.
    @State private var opened: Set<Int> = []

    /// Changed lines with three lines of context; longer unchanged runs fold into one row.
    private enum Row: Identifiable {
        case line(Diff.Line)
        case fold(start: Int, count: Int)

        var id: String {
            switch self {
            case .line(let line): "l\(line.id)"
            case .fold(let start, _): "f\(start)"
            }
        }
    }

    private var rows: [Row] {
        let context = 3
        var keep = Set<Int>()
        for line in lines where line.kind != .same {
            for index in max(0, line.id - context)...min(lines.count - 1, line.id + context) { keep.insert(index) }
        }
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            if keep.contains(index) || lines[index].kind != .same {
                rows.append(.line(lines[index]))
                index += 1
                continue
            }
            var end = index
            while end < lines.count, !keep.contains(end), lines[end].kind == .same { end += 1 }
            if opened.contains(index) || end - index < 2 {
                rows += lines[index..<end].map(Row.line)
            } else {
                rows.append(.fold(start: index, count: end - index))
            }
            index = end
        }
        return rows
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .line(let line): LineRow(line: line)
                    case .fold(let start, let count):
                        Button { opened.insert(start) } label: {
                            Text("⋯  \(count) unchanged line\(count == 1 ? "" : "s")")
                                .font(Theme.caption(11, weight: .medium))
                                .foregroundStyle(Theme.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.leading, 70)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .scrollIndicators(.automatic)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.03)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct LineRow: View {
    let line: Diff.Line

    var body: some View {
        let tint: Color = line.kind == .added ? Theme.green : line.kind == .removed ? Theme.red : .clear
        HStack(alignment: .top, spacing: 0) {
            Text(line.left.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
            Text(line.right.map(String.init) ?? "").frame(width: 30, alignment: .trailing)
            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(attributed)
                .foregroundStyle(line.kind == .same ? Theme.secondary : Theme.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(Theme.tertiary)
        .padding(.vertical, 1.5)
        .padding(.trailing, 8)
        .background(tint.opacity(0.1))
    }

    /// The line with its changed words lit up.
    private var attributed: AttributedString {
        var text = AttributedString(line.text.isEmpty ? " " : line.text)
        guard !line.changed.isEmpty else { return text }
        let tint: Color = line.kind == .added ? Theme.green : Theme.red
        for range in line.changed {
            let lower = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
            let length = line.text.distance(from: range.lowerBound, to: range.upperBound)
            let start = text.index(text.startIndex, offsetByCharacters: lower)
            let end = text.index(start, offsetByCharacters: length)
            text[start..<end].backgroundColor = tint.opacity(0.35)
        }
        return text
    }
}

// MARK: Structure

private struct ChangesView: View {
    let changes: [Diff.Change]

    var body: some View {
        if changes.isEmpty {
            EmptyState(icon: "checkmark.circle", title: "No differences", subtitle: "Same keys and values. Order and formatting don't count.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(changes) { change in
                        ChangeRow(change: change)
                    }
                }
                .textSelection(.enabled)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct ChangeRow: View {
    let change: Diff.Change

    var body: some View {
        let tint = change.kind == .added ? Theme.green : change.kind == .removed ? Theme.red : Theme.orange
        HStack(alignment: .top, spacing: 10) {
            Capsule().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(change.path).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.primary)
                    Text(change.kind == .added ? "added" : change.kind == .removed ? "removed" : "changed")
                        .font(Theme.caption(10.5, weight: .semibold))
                        .foregroundStyle(tint)
                }
                if let old = change.old {
                    Text("− " + old).foregroundStyle(Theme.red.opacity(0.9))
                }
                if let new = change.new {
                    Text("+ " + new).foregroundStyle(Theme.green.opacity(0.9))
                }
            }
            .font(.system(size: 11.5, design: .monospaced))
            .lineLimit(4)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.card))
    }
}

// MARK: Images

private struct ImageDiffView: View {
    let result: Diff.ImageResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if result.sizes.0 != result.sizes.1 {
                Text("Different sizes: \(Int(result.sizes.0.width)) × \(Int(result.sizes.0.height)) and \(Int(result.sizes.1.width)) × \(Int(result.sizes.1.height)). B is scaled to A.")
                    .font(Theme.caption(11.5, weight: .regular))
                    .foregroundStyle(Theme.orange)
            }
            if let overlay = result.overlay {
                Image(nsImage: overlay)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("Red marks the pixels that differ.").font(Theme.caption(10.5, weight: .regular)).foregroundStyle(Theme.tertiary)
            }
        }
    }
}
