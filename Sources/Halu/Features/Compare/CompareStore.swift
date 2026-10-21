import AppKit
import PDFKit
import UniformTypeIdentifiers

/// Two things side by side and what differs between them: pasted text, JSON, PDFs (text or filled-in
/// form fields), Word/RTF/ODT/Markdown and other text files, or images. Everything runs locally with
/// what macOS has built in. Both sides survive the panel closing.
@MainActor
final class CompareStore: ObservableObject {
    struct Input {
        enum Kind: String { case text = "Text", json = "JSON", pdf = "PDF", document = "Document", image = "Image" }

        var name: String
        var kind: Kind
        var detail: String
        var text: String = ""
        /// Parsed JSON, or a PDF's form fields as name → value.
        var structure: Any?
        var image: NSImage?

        var icon: String {
            switch kind {
            case .text: "text.alignleft"
            case .json: "curlybraces"
            case .pdf: "doc.richtext"
            case .document: "doc.text"
            case .image: "photo"
            }
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text", structure = "Structure"
        var id: String { rawValue }
    }

    enum Result {
        case lines([Diff.Line])
        case changes([Diff.Change])
        case image(Diff.ImageResult)
        case problem(String)
    }

    @Published private(set) var left: Input?
    @Published private(set) var right: Input?
    @Published var mode: Mode = .structure { didSet { compare() } }
    @Published var options = Diff.TextOptions() { didSet { compare() } }
    @Published private(set) var result: Result?
    @Published private(set) var problem: String?

    /// Structure is offered for two JSONs, or two PDFs that both have form fields.
    var canCompareStructure: Bool { left?.structure != nil && right?.structure != nil }

    /// Fills the given side, or the first empty one.
    func load(_ url: URL, into side: Bool? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let input = Self.read(url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let input else {
                        self.problem = "Can't read \(url.lastPathComponent)."
                        return
                    }
                    // Without a side: the empty one, else the right one is replaced.
                    self.set(input, left: side ?? (self.left == nil))
                }
            }
        }
    }

    func load(providers: [NSItemProvider], into side: Bool? = nil) {
        for (index, provider) in providers.prefix(2).enumerated() {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // Two files dropped at once fill both sides.
                        let target: Bool? = side ?? (providers.count > 1 ? index == 0 : nil)
                        self.load(url, into: target)
                    }
                }
            }
        }
    }

    /// Text or a copied file from the clipboard.
    func paste(intoLeft: Bool) {
        let board = NSPasteboard.general
        if let url = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first {
            load(url, into: intoLeft)
        } else if let text = board.string(forType: .string), !text.isEmpty {
            set(Self.input(text: text, name: "Pasted text"), left: intoLeft)
        } else if let image = NSImage(pasteboard: board) {
            set(Input(name: "Pasted image", kind: .image, detail: Self.dimensions(image), image: image), left: intoLeft)
        }
    }

    func choose(intoLeft: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { load(url, into: intoLeft) }
    }

    func clear(left isLeft: Bool) {
        if isLeft { left = nil } else { right = nil }
        problem = nil
        compare()
    }

    func swap() {
        (left, right) = (right, left)
        compare()
    }

    private func set(_ input: Input, left isLeft: Bool) {
        problem = nil
        if isLeft { left = input } else { right = input }
        // A new pair of JSONs or form PDFs starts in Structure; anything else in Text.
        if let left, let right { mode = left.structure != nil && right.structure != nil ? .structure : .text }
        compare()
    }

    private func compare() {
        guard let left, let right else {
            result = nil
            return
        }
        if left.kind == .image || right.kind == .image {
            guard let a = left.image, let b = right.image else {
                result = .problem("An image can only be compared with another image.")
                return
            }
            result = Diff.images(a, b).map(Result.image) ?? .problem("Couldn't read these images.")
        } else if mode == .structure, let a = left.structure, let b = right.structure {
            result = .changes(Diff.structure(a, b))
        } else {
            let options = options
            let (a, b) = (left.text, right.text)
            guard a.count + b.count < 4_000_000 else {
                result = .problem("These are too large to compare here.")
                return
            }
            result = .lines(Diff.lines(a, b, options: options))
        }
    }

    // MARK: Reading

    private nonisolated static func read(_ url: URL) -> Input? {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        let type = UTType(filenameExtension: url.pathExtension.lowercased())

        if type?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(url: url) else { return nil }
            let fields = formFields(pdf)
            var input = Input(name: name, kind: .pdf, detail: "PDF · \(pdf.pageCount) page\(pdf.pageCount == 1 ? "" : "s")"
                                  + (fields.isEmpty ? "" : " · \(fields.count) fields") + " · \(size)", text: pdf.string ?? "")
            input.structure = fields.isEmpty ? nil : fields
            return input
        }
        if type?.conforms(to: .image) == true {
            guard let image = NSImage(contentsOf: url) else { return nil }
            return Input(name: name, kind: .image, detail: "\(dimensions(image)) · \(size)", image: image)
        }
        // Word, RTF, ODT, HTML: the text as macOS reads it.
        let documentTypes: [String: NSAttributedString.DocumentType] = [
            "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "rtf": .rtf, "rtfd": .rtfd,
            "html": .html, "htm": .html, "webarchive": .webArchive,
        ]
        if let documentType = documentTypes[url.pathExtension.lowercased()] {
            guard let document = try? NSAttributedString(url: url, options: [.documentType: documentType], documentAttributes: nil)
            else { return nil }
            return Input(name: name, kind: .document, detail: "\(url.pathExtension.uppercased()) · \(size)", text: document.string)
        }
        guard let data = try? Data(contentsOf: url), let text = decode(data) else { return nil }
        var input = Self.input(text: text, name: name)
        input.detail = (input.kind == .json ? "JSON" : url.pathExtension.uppercased()) + " · \(size)"
        return input
    }

    private nonisolated static func input(text: String, name: String) -> Input {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" || trimmed.first == "[",
           let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
            // Text mode compares the pretty-printed, key-sorted form, so formatting never shows up as a change.
            let pretty = (try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? text
            return Input(name: name, kind: .json, detail: "JSON", text: pretty, structure: json)
        }
        let lines = text.components(separatedBy: "\n").count
        return Input(name: name, kind: .text, detail: "\(lines) line\(lines == 1 ? "" : "s")", text: text)
    }

    /// Filled-in form fields of a PDF, by field name. Checkboxes and radio buttons give their state.
    private nonisolated static func formFields(_ pdf: PDFDocument) -> [String: Any] {
        var fields: [String: Any] = [:]
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            for annotation in page.annotations where annotation.type == "Widget" {
                let name = annotation.fieldName ?? "Page \(index + 1) field"
                switch annotation.widgetFieldType {
                case .button:
                    let on = annotation.buttonWidgetState == .onState
                    if annotation.widgetControlType == .radioButtonControl {
                        if on { fields[name] = annotation.buttonWidgetStateString } else if fields[name] == nil { fields[name] = NSNull() }
                    } else {
                        fields[name] = NSNumber(value: on)
                    }
                case .text, .choice:
                    fields[name] = annotation.widgetStringValue ?? ""
                default:
                    break
                }
            }
        }
        return fields
    }

    private nonisolated static func decode(_ data: Data) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        return String(data: data, encoding: .windowsCP1251)
    }

    private nonisolated static func dimensions(_ image: NSImage) -> String {
        guard let rep = image.representations.first else { return "Image" }
        return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
    }
}
