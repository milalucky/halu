import AppKit

/// The comparisons behind the Compare tab: lines of text, JSON (or PDF form fields) by path, and images
/// pixel by pixel. Pure functions, no state.
enum Diff {
    // MARK: Text

    struct Line: Identifiable, Equatable {
        enum Kind { case same, added, removed }
        var id: Int
        var kind: Kind
        var left: Int?
        var right: Int?
        var text: String
        /// Ranges of `text` that changed inside a line that was edited, not replaced.
        var changed: [Range<String.Index>] = []
    }

    struct TextOptions: Equatable {
        var ignoreWhitespace = false
        var ignoreCase = false
    }

    static func lines(_ left: String, _ right: String, options: TextOptions) -> [Line] {
        let a = split(left), b = split(right)
        let key = { (line: String) -> String in
            var line = line
            if options.ignoreWhitespace { line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            if options.ignoreCase { line = line.lowercased() }
            return line
        }
        let difference = b.map(key).difference(from: a.map(key))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var result: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                result.append(Line(id: result.count, kind: .removed, left: i + 1, text: a[i]))
                i += 1
            } else if j < b.count, inserted.contains(j) {
                result.append(Line(id: result.count, kind: .added, right: j + 1, text: b[j]))
                j += 1
            } else {
                result.append(Line(id: result.count, kind: .same, left: i + 1, right: j + 1, text: i < a.count ? a[i] : b[j]))
                i += 1
                j += 1
            }
        }
        markWords(&result)
        return result
    }

    private static func split(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    }

    /// In each block of removed lines followed by added lines, pairs similar lines and marks the words
    /// that differ, so an edited value stands out instead of the whole line.
    private static func markWords(_ lines: inout [Line]) {
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else { index += 1; continue }
            var removedEnd = index
            while removedEnd < lines.count, lines[removedEnd].kind == .removed { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd < lines.count, lines[addedEnd].kind == .added { addedEnd += 1 }
            // Each added line goes with the removed line it shares the most words with.
            var taken = Set<Int>()
            for new in removedEnd..<addedEnd where lines[new].text.count < 2000 {
                let words = Set(tokens(lines[new].text).map(\.text))
                guard !words.isEmpty else { continue }
                let best = (index..<removedEnd).filter { !taken.contains($0) && lines[$0].text.count < 2000 }
                    .map { old in (old, Set(tokens(lines[old].text).map(\.text)).intersection(words).count) }
                    .max { $0.1 < $1.1 }
                guard let (old, shared) = best, Double(shared) / Double(words.count) >= 0.3 else { continue }
                taken.insert(old)
                let (oldRanges, newRanges) = changedWords(lines[old].text, lines[new].text)
                // Mostly rewritten lines read better whole.
                if oldRanges.count + newRanges.count <= 12 {
                    lines[old].changed = oldRanges
                    lines[new].changed = newRanges
                }
            }
            index = max(addedEnd, index + 1)
        }
    }

    private static func changedWords(_ old: String, _ new: String) -> ([Range<String.Index>], [Range<String.Index>]) {
        let a = tokens(old), b = tokens(new)
        let difference = b.map(\.text).difference(from: a.map(\.text))
        var oldRanges: [Range<String.Index>] = [], newRanges: [Range<String.Index>] = []
        for change in difference {
            switch change {
            case .remove(let offset, _, _): oldRanges.append(a[offset].range)
            case .insert(let offset, _, _): newRanges.append(b[offset].range)
            }
        }
        return (oldRanges, newRanges)
    }

    /// Words, numbers and single punctuation marks, with where they sit.
    private static func tokens(_ text: String) -> [(text: Substring, range: Range<String.Index>)] {
        var result: [(Substring, Range<String.Index>)] = []
        var index = text.startIndex
        while index < text.endIndex {
            let char = text[index]
            var end = text.index(after: index)
            if char.isLetter || char.isNumber {
                while end < text.endIndex, text[end].isLetter || text[end].isNumber { end = text.index(after: end) }
            } else if char.isWhitespace {
                while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
            }
            if !char.isWhitespace { result.append((text[index..<end], index..<end)) }
            index = end
        }
        return result
    }

    // MARK: Structure

    struct Change: Identifiable, Equatable {
        enum Kind { case added, removed, changed }
        var id: String { path }
        var path: String
        var kind: Kind
        var old: String?
        var new: String?
    }

    /// Differences between two JSON values (or form field maps), by path like `user.items[2].name`.
    /// Key order and formatting don't matter.
    static func structure(_ left: Any, _ right: Any) -> [Change] {
        var changes: [Change] = []
        walk(left, right, path: "", into: &changes)
        return changes
    }

    private static func walk(_ left: Any, _ right: Any, path: String, into changes: inout [Change]) {
        switch (left, right) {
        case let (l as [String: Any], r as [String: Any]):
            for key in Set(l.keys).union(r.keys).sorted() {
                let child = path.isEmpty ? key : "\(path).\(key)"
                switch (l[key], r[key]) {
                case let (a?, b?): walk(a, b, path: child, into: &changes)
                case let (a?, nil): changes.append(Change(path: child, kind: .removed, old: render(a)))
                case let (nil, b?): changes.append(Change(path: child, kind: .added, new: render(b)))
                default: break
                }
            }
        case let (l as [Any], r as [Any]):
            for index in 0..<max(l.count, r.count) {
                let child = "\(path)[\(index)]"
                if index >= r.count {
                    changes.append(Change(path: child, kind: .removed, old: render(l[index])))
                } else if index >= l.count {
                    changes.append(Change(path: child, kind: .added, new: render(r[index])))
                } else {
                    walk(l[index], r[index], path: child, into: &changes)
                }
            }
        default:
            if !same(left, right) {
                changes.append(Change(path: path.isEmpty ? "(value)" : path, kind: .changed, old: render(left), new: render(right)))
            }
        }
    }

    private static func same(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case let (x as NSNumber, y as NSNumber):
            // true and 1 are different values in JSON.
            return isBool(x) == isBool(y) && x == y
        case let (x as String, y as String): return x == y
        case (is NSNull, is NSNull): return true
        default: return false
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    static func render(_ value: Any) -> String {
        if let number = value as? NSNumber, isBool(number) { return number.boolValue ? "true" : "false" }
        if value is NSNull { return "null" }
        if let string = value as? String { return "\"\(string)\"" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 300 ? String(text.prefix(300)) + "…" : text
        }
        return "\(value)"
    }

    // MARK: Images

    struct ImageResult {
        var sizes: (CGSize, CGSize)
        /// Share of pixels that differ, 0…1.
        var differing: Double
        /// The left image faded, with differing pixels in red.
        var overlay: NSImage?
    }

    static func images(_ left: NSImage, _ right: NSImage) -> ImageResult? {
        guard let a = left.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let b = right.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let sizes = (CGSize(width: a.width, height: a.height), CGSize(width: b.width, height: b.height))
        // Compared at the left image's proportions, at most 1200 px across, so it stays quick.
        let scale = min(1, 1200 / Double(max(a.width, a.height)))
        let width = max(1, Int(Double(a.width) * scale)), height = max(1, Int(Double(a.height) * scale))
        guard let pa = pixels(a, width, height), let pb = pixels(b, width, height) else { return nil }
        var out = [UInt8](repeating: 0, count: width * height * 4)
        var differing = 0
        for p in stride(from: 0, to: pa.count, by: 4) {
            let delta = abs(Int(pa[p]) - Int(pb[p])) + abs(Int(pa[p + 1]) - Int(pb[p + 1])) + abs(Int(pa[p + 2]) - Int(pb[p + 2]))
                + abs(Int(pa[p + 3]) - Int(pb[p + 3]))
            if delta > 24 {
                differing += 1
                out[p] = 255; out[p + 1] = 60; out[p + 2] = 60; out[p + 3] = 255
            } else {
                let gray = UInt8((Int(pa[p]) + Int(pa[p + 1]) + Int(pa[p + 2])) / 3 / 4 + 20)
                out[p] = gray; out[p + 1] = gray; out[p + 2] = gray; out[p + 3] = 255
            }
        }
        let overlay = CGDataProvider(data: Data(out) as CFData).flatMap {
            CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }.map { NSImage(cgImage: $0, size: NSSize(width: width, height: height)) }
        return ImageResult(sizes: sizes, differing: Double(differing) / Double(width * height), overlay: overlay)
    }

    private static func pixels(_ image: CGImage, _ width: Int, _ height: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? buffer : nil
    }
}
