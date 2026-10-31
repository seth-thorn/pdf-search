// PDF Search — drag in PDFs, search every word, see the hits highlighted.
// One file, no dependencies: SwiftUI + PDFKit + the SQLite that ships with macOS.

import SwiftUI
import AppKit
import PDFKit
import SQLite3
import UniformTypeIdentifiers

// MARK: - App

@main
struct PDFSearchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var lib = Library.shared

    var body: some Scene {
        Window("PDF Search", id: "main") {
            ContentView()
                .environmentObject(lib)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add PDFs or Folders…") { lib.choose() }
                    .keyboardShortcut("o")
                Divider()
                Button("Rescan Folders") { lib.refresh() }
                    .keyboardShortcut("r")
                Button("Clear Index…") { lib.confirmClear() }
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in This PDF…") { lib.findRequest += 1 }
                    .keyboardShortcut("f")
                Button("Highlight Selection / Highlighter") { lib.highlightRequest += 1 }
                    .keyboardShortcut("h", modifiers: [.command, .control])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // PDFs or folders dropped on the Dock icon
    func application(_ application: NSApplication, open urls: [URL]) { Library.shared.add(urls) }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var lib: Library
    @StateObject private var viewer = Viewer()
    @State private var selection: Int?
    @State private var dropTargeted = false
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    /// ⌘F text, searched as one phrase, anywhere in a word (like Preview)
    var findTerms: [String] {
        let t = findText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? [] : [t]
    }
    var findMode: Bool { showFind && !findTerms.isEmpty }
    var activeTerms: [String] { findMode ? findTerms : lib.terms }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 560)
        } detail: {
            detail
        }
        .searchable(text: $lib.query, placement: .sidebar, prompt: Text(searchPrompt))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, lineWidth: 4)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: selection) { _ in showSelected() }
        .onChange(of: lib.terms) { _ in
            if !findMode, let p = viewer.path { viewer.show(path: p, terms: lib.terms, page: 0) }
        }
        .onChange(of: lib.findRequest) { _ in openFind() }
        .onChange(of: lib.highlightRequest) { _ in viewer.highlightKey() }
        .task(id: findText) {
            guard showFind else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let p = viewer.path else { return }
            viewer.show(path: p, terms: activeTerms, page: 0, wholeWords: !findMode)
        }
    }

    // Sidebar: results list + status line
    var searchPrompt: String {
        if let s = lib.scope, let f = lib.folders.first(where: { $0.path == s }) { return "Search \(f.name)" }
        return "Search all PDFs"
    }

    var scopeBar: some View {
        HStack(spacing: 6) {
            Picker("Search in", selection: $lib.scope) {
                Text("All PDFs (\(lib.docCount))").tag(String?.none)
                Divider()
                ForEach(lib.folders) { f in
                    Text("\(f.name) (\(f.count))").tag(Optional(f.path))
                }
            }
            .pickerStyle(.menu)
            Menu {
                if let s = lib.scope {
                    Button("Rename…") { lib.renameFolder(s) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s)]) }
                    Divider()
                    Button("Remove Folder from Index…") { lib.removeFolder(s) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(lib.scope == nil)
            .help("Rename, show or remove this folder")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            if !lib.folders.isEmpty {
                scopeBar
                Divider()
            }
            if lib.docCount == 0 && lib.progress == nil {
                emptyState
            } else {
                List(lib.results, selection: $selection) { hit in
                    HitRow(hit: hit)
                }
                .contextMenu(forSelectionType: Int.self) { ids in
                    Button("Open in Preview") { openFiles(ids) }
                    Button("Show in Finder") { reveal(ids) }
                    Divider()
                    Button("Remove from Index") { lib.remove(Array(ids)) }
                } primaryAction: { ids in
                    openFiles(ids)
                }
                .overlay {
                    if lib.results.isEmpty && !lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("No matches").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            statusBar
        }
        .toolbar {
            ToolbarItem {
                Button { lib.choose() } label: { Label("Add PDFs", systemImage: "plus") }
                    .help("Add PDFs or folders (or just drag them into the window)")
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop PDFs or folders here")
                .font(.title3.weight(.medium))
            Text("Everything inside gets indexed so you can\nsearch every word in every PDF.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Choose…") { lib.choose() }
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var statusBar: some View {
        HStack(spacing: 8) {
            if let p = lib.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 70)
                Text("Indexing \(p.done) of \(p.total)…")
            } else if let err = lib.errorMessage {
                Text(err).foregroundStyle(.red)
            } else if lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(lib.scopedCount) PDFs")
            } else {
                Text("\(lib.results.count) of \(lib.scopedCount) PDFs")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // Detail: the PDF itself
    var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in this PDF", text: $findText)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { viewer.step(1) }
                .onExitCommand { closeFind() }
                .frame(maxWidth: 280)
            if findMode {
                Text(viewer.matchCount == 0 ? "No matches" : "\(viewer.matchIndex + 1) of \(viewer.matchCount)")
                    .monospacedDigit()
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button { viewer.step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(viewer.matchCount == 0)
                .help("Previous (⇧⌘G)")
            Button { viewer.step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(viewer.matchCount == 0)
                .help("Next (Return or ⌘G)")
            Spacer()
            Button("Done") { closeFind() }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    var detail: some View {
        VStack(spacing: 0) {
            if showFind {
                findBar
                Divider()
            }
            pdfArea
        }
    }

    var pdfArea: some View {
        PDFKitView(view: viewer.pdfView)
            .overlay {
                if viewer.path == nil {
                    Text(lib.docCount == 0 ? "" : "Select a PDF to see where your words appear")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                } else if viewer.missing {
                    VStack(spacing: 10) {
                        Text("This file has been moved or deleted.").foregroundStyle(.secondary)
                        Button("Rescan Folders") { lib.refresh() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
            .navigationTitle(viewer.title)
            .toolbar {
                ToolbarItemGroup {
                    if viewer.matchCount > 0 {
                        Text("\(viewer.matchIndex + 1) of \(viewer.matchCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Button { viewer.step(-1) } label: { Label("Previous Match", systemImage: "chevron.up") }
                        .disabled(viewer.matchCount == 0)
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                        .help("Previous match (⇧⌘G)")
                    Button { viewer.step(1) } label: { Label("Next Match", systemImage: "chevron.down") }
                        .disabled(viewer.matchCount == 0)
                        .keyboardShortcut("g", modifiers: .command)
                        .help("Next match (⌘G)")
                    Toggle(isOn: $viewer.highlighter) {
                        Label("Highlighter", systemImage: "highlighter")
                    }
                        .toggleStyle(.button)
                        .disabled(viewer.path == nil)
                        .help("Highlighter (⌃⌘H): select text to highlight it. Highlights are saved into the PDF.")
                    Menu {
                        ForEach(HighlightColor.allCases) { c in
                            Button { viewer.highlightColor = c } label: {
                                if viewer.highlightColor == c { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                            }
                        }
                    } label: {
                        Label("Highlight Color", systemImage: "paintpalette")
                    }
                        .help("Highlight color")
                    Button { viewer.zoomToFit() } label: {
                        Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                    }
                        .disabled(viewer.path == nil)
                        .keyboardShortcut("0", modifiers: .command)
                        .help("Zoom to fit (⌘0)")
                    Button {
                        if let p = viewer.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                    } label: { Label("Open in Preview", systemImage: "arrow.up.forward.app") }
                        .disabled(viewer.path == nil)
                        .help("Open in your default PDF app")
                }
            }
    }

    // MARK: actions

    func showSelected() {
        guard let id = selection, let hit = lib.results.first(where: { $0.id == id }) else { return }
        viewer.show(path: hit.path, terms: activeTerms, page: hit.page, wholeWords: !findMode)
    }

    func openFind() {
        showFind = true
        DispatchQueue.main.async { findFocused = true }
    }

    func closeFind() {
        showFind = false
        findText = ""
        findFocused = false
        if let p = viewer.path { viewer.show(path: p, terms: lib.terms, page: 0) }
    }

    func paths(_ ids: Set<Int>) -> [URL] {
        lib.results.filter { ids.contains($0.id) }.map { URL(fileURLWithPath: $0.path) }
    }
    func openFiles(_ ids: Set<Int>) { paths(ids).forEach { NSWorkspace.shared.open($0) } }
    func reveal(_ ids: Set<Int>) { NSWorkspace.shared.activateFileViewerSelecting(paths(ids)) }

    func handleDrop(_ providers: [NSItemProvider]) {
        let lib = self.lib
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url = url { lock.lock(); urls.append(url); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { lib.add(urls) }
    }
}

struct HitRow: View {
    let hit: Hit
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.name).font(.headline).lineLimit(1)
                Spacer(minLength: 6)
                Text(hit.badge).font(.caption).foregroundStyle(.secondary)
            }
            if let s = hit.snippet {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Text(hit.folder).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - PDF viewer with highlighted matches

struct PDFKitView: NSViewRepresentable {
    let view: PDFView
    func makeNSView(context: Context) -> PDFView { view }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, green, blue, pink, purple
    var id: String { rawValue }
    var name: String { rawValue.capitalized }
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(srgbRed: 1.00, green: 0.86, blue: 0.10, alpha: 0.5)
        case .green:  return NSColor(srgbRed: 0.45, green: 0.86, blue: 0.35, alpha: 0.5)
        case .blue:   return NSColor(srgbRed: 0.40, green: 0.70, blue: 1.00, alpha: 0.5)
        case .pink:   return NSColor(srgbRed: 1.00, green: 0.45, blue: 0.65, alpha: 0.5)
        case .purple: return NSColor(srgbRed: 0.70, green: 0.50, blue: 1.00, alpha: 0.5)
        }
    }
}

/// PDFView with "Highlight" / "Remove Highlight" in its right-click menu.
final class HighlightingPDFView: PDFView {
    var onHighlight: ((PDFSelection) -> Void)?
    var onRemove: ((PDFAnnotation) -> Void)?

    static func isHighlight(_ a: PDFAnnotation) -> Bool {
        (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Highlight"
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var extra: [NSMenuItem] = []
        if let sel = currentSelection, let text = sel.string, text.contains(where: { !$0.isWhitespace }) {
            let item = NSMenuItem(title: "Highlight", action: #selector(highlightSelectionItem(_:)), keyEquivalent: "")
            item.target = self
            extra.append(item)
        }
        let pt = convert(event.locationInWindow, from: nil)
        if let page = page(for: pt, nearest: false) {
            let pagePoint = convert(pt, to: page)
            if let ann = page.annotation(at: pagePoint), HighlightingPDFView.isHighlight(ann) {
                let item = NSMenuItem(title: "Remove Highlight", action: #selector(removeHighlightItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ann
                extra.append(item)
            }
        }
        if !extra.isEmpty {
            menu.insertItem(.separator(), at: 0)
            for item in extra.reversed() { menu.insertItem(item, at: 0) }
        }
        return menu
    }

    @objc private func highlightSelectionItem(_ sender: NSMenuItem) {
        if let sel = currentSelection { onHighlight?(sel) }
    }
    @objc private func removeHighlightItem(_ sender: NSMenuItem) {
        if let ann = sender.representedObject as? PDFAnnotation { onRemove?(ann) }
    }
}

final class Viewer: ObservableObject {
    let pdfView: HighlightingPDFView = {
        let v = HighlightingPDFView()
        v.autoScales = false   // we manage zoom ourselves so a pinch-zoom sticks
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        return v
    }()
    @Published private(set) var path: String?
    @Published private(set) var title = "PDF Search"
    @Published private(set) var matchCount = 0
    @Published private(set) var matchIndex = 0
    @Published private(set) var missing = false
    private var selections: [PDFSelection] = []
    private var gen = 0
    private let queue = DispatchQueue(label: "pdfsearch.viewer", qos: .userInitiated)
    /// The zoom the user chose by pinching / ⌘+ / ⌘−. nil = fit to window.
    private var userScale: CGFloat?
    private var settingScale = false
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?

    /// Highlighter tool: when on, any text you select gets highlighted on mouse-up.
    @Published var highlighter = false
    @Published var highlightColor: HighlightColor =
        HighlightColor(rawValue: UserDefaults.standard.string(forKey: "highlightColor") ?? "") ?? .yellow {
        didSet { UserDefaults.standard.set(highlightColor.rawValue, forKey: "highlightColor") }
    }
    private var unsaved = false
    private var saveWork: DispatchWorkItem?

    init() {
        let nc = NotificationCenter.default
        // Any zoom we didn't set ourselves came from the user: remember it.
        observers.append(nc.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: nil) { [weak self] _ in
            guard let self = self, !self.settingScale, self.pdfView.document != nil else { return }
            self.userScale = self.pdfView.scaleFactor
        })
        // While nothing has been zoomed, keep the page fitted when the window or sidebar changes size.
        pdfView.postsFrameChangedNotifications = true
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: pdfView, queue: nil) { [weak self] _ in
            guard let self = self, self.userScale == nil else { return }
            self.applyScale()
        })
        observers.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushSave()
        })
        pdfView.onHighlight = { [weak self] sel in self?.addHighlight(sel) }
        pdfView.onRemove = { [weak self] ann in self?.removeHighlight(ann) }
        // Highlighter mode: after a drag/double-click in the PDF, highlight whatever got selected.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            if let self = self, self.highlighter, event.window === self.pdfView.window {
                let p = self.pdfView.convert(event.locationInWindow, from: nil)
                if self.pdfView.bounds.contains(p) {
                    DispatchQueue.main.async { self.highlightCurrentSelection() }
                }
            }
            return event
        }
    }

    // MARK: highlights (saved into the PDF file, like Preview)

    /// ⌃⌘H: highlight the selection if there is one, otherwise switch the highlighter on/off.
    func highlightKey() {
        if !highlightCurrentSelection() { highlighter.toggle() }
    }

    @discardableResult
    private func highlightCurrentSelection() -> Bool {
        guard let sel = pdfView.currentSelection, let text = sel.string,
              text.contains(where: { !$0.isWhitespace }) else { return false }
        addHighlight(sel)
        return true
    }

    func addHighlight(_ sel: PDFSelection) {
        guard pdfView.document != nil else { return }
        // one annotation per page, one quad per line (like Preview)
        var byPage: [PDFPage: [CGRect]] = [:]
        var order: [PDFPage] = []
        for line in sel.selectionsByLine() {
            for page in line.pages {
                let r = line.bounds(for: page)
                guard r.width > 0.5, r.height > 0.5 else { continue }
                if byPage[page] == nil { order.append(page) }
                byPage[page, default: []].append(r)
            }
        }
        for page in order {
            guard let rects = byPage[page], let first = rects.first else { continue }
            let box = rects.dropFirst().reduce(first) { $0.union($1) }
            let ann = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
            ann.color = highlightColor.nsColor
            ann.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - box.minX, x1 = r.maxX - box.minX
                let y0 = r.minY - box.minY, y1 = r.maxY - box.minY
                return [NSValue(point: NSPoint(x: x0, y: y1)), NSValue(point: NSPoint(x: x1, y: y1)),
                        NSValue(point: NSPoint(x: x0, y: y0)), NSValue(point: NSPoint(x: x1, y: y0))]
            }
            ann.userName = NSFullUserName()
            ann.modificationDate = Date()
            page.addAnnotation(ann)
        }
        pdfView.clearSelection()
        markUnsaved()
    }

    func removeHighlight(_ ann: PDFAnnotation) {
        ann.page?.removeAnnotation(ann)
        markUnsaved()
    }

    private func markUnsaved() {
        unsaved = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Write the open PDF back to disk (via a temp file, then swap it in).
    func flushSave() {
        saveWork?.cancel()
        saveWork = nil
        guard unsaved, let doc = pdfView.document, let url = doc.documentURL else { return }
        unsaved = false
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pdfsearch-saving")
        var ok = doc.write(to: tmp)
        if ok {
            do { _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp) } catch { ok = false }
        }
        if !ok {
            try? FileManager.default.removeItem(at: tmp)
            let alert = NSAlert()
            alert.messageText = "Couldn't save the highlights"
            alert.informativeText = "“\(url.lastPathComponent)” may be locked, read-only or password-protected."
            alert.runModal()
        }
    }

    private func applyScale() {
        guard pdfView.document != nil else { return }
        settingScale = true
        pdfView.autoScales = false
        pdfView.scaleFactor = userScale ?? pdfView.scaleFactorForSizeToFit
        settingScale = false
    }

    func zoomToFit() {
        userScale = nil
        applyScale()
    }

    func show(path: String, terms: [String], page: Int, wholeWords: Bool = true) {
        flushSave()
        gen += 1
        let g = gen
        let sameDoc = (path == self.path) && pdfView.document != nil
        let keepPage = sameDoc ? pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } : nil
        self.path = path
        self.title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

        queue.async {
            // Load a fresh copy off the main thread and find every match in it,
            // then hand the finished document to the view.
            let doc = FileManager.default.fileExists(atPath: path) ? PDFDocument(url: URL(fileURLWithPath: path)) : nil
            var sels: [PDFSelection] = []
            if let doc = doc, !doc.isLocked {
                for t in terms {
                    let found = doc.findString(t, withOptions: [.caseInsensitive, .diacriticInsensitive])
                    sels += wholeWords ? found.filter(Viewer.startsAtWord) : found
                    if sels.count > 5000 { break }
                }
                sels.sort { a, b in
                    guard let pa = a.pages.first, let pb = b.pages.first else { return false }
                    let ia = doc.index(for: pa), ib = doc.index(for: pb)
                    if ia != ib { return ia < ib }
                    let ra = a.bounds(for: pa), rb = b.bounds(for: pb)
                    if abs(ra.maxY - rb.maxY) > 2 { return ra.maxY > rb.maxY }
                    return ra.minX < rb.minX
                }
                let hitColor = NSColor.systemOrange.withAlphaComponent(0.45)  // search hits: orange, so they don't look like saved highlights
                sels.forEach { $0.color = hitColor }
            }
            DispatchQueue.main.async {
                guard g == self.gen else { return }
                self.missing = (doc == nil)
                self.pdfView.highlightedSelections = nil
                self.settingScale = true
                self.pdfView.document = doc
                self.settingScale = false
                self.applyScale()
                self.selections = sels
                self.matchCount = sels.count
                self.matchIndex = 0
                self.pdfView.highlightedSelections = sels.isEmpty ? nil : sels
                if !sels.isEmpty {
                    self.focus(0)
                } else if let doc = doc {
                    let idx = keepPage ?? max(page - 1, 0)
                    if let p = doc.page(at: min(idx, max(doc.pageCount - 1, 0))) { self.pdfView.go(to: p) }
                }
            }
        }
    }

    func step(_ delta: Int) { focus(matchIndex + delta) }

    private func focus(_ i: Int) {
        guard !selections.isEmpty else { return }
        let n = selections.count
        matchIndex = ((i % n) + n) % n
        let s = selections[matchIndex]
        pdfView.setCurrentSelection(s, animate: true)
        pdfView.go(to: s)
    }

    /// Search hits should start at the beginning of a word ("art" shouldn't light up "start").
    static func startsAtWord(_ s: PDFSelection) -> Bool {
        guard let c = s.copy() as? PDFSelection, let orig = s.string else { return true }
        c.extend(atStart: 1)
        guard let ext = c.string, ext.count > orig.count, let first = ext.unicodeScalars.first else { return true }
        return !CharacterSet.alphanumerics.contains(first)
    }
}

// MARK: - Library: the index and everything that talks to it

struct Hit: Identifiable {
    let id: Int
    let path: String
    let page: Int
    let badge: String
    let snippet: AttributedString?
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var folder: String {
        let dir = (path as NSString).deletingLastPathComponent
        let home = NSHomeDirectory()
        return dir.hasPrefix(home) ? "~" + dir.dropFirst(home.count) : dir
    }
}

struct Folder: Identifiable, Hashable {
    let path: String
    let name: String
    let count: Int
    var id: String { path }
}

final class Library: ObservableObject {
    static let shared = Library()

    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published private(set) var results: [Hit] = []
    @Published private(set) var terms: [String] = []
    @Published private(set) var docCount = 0
    @Published private(set) var progress: (done: Int, total: Int)?
    @Published private(set) var errorMessage: String?
    @Published private(set) var folders: [Folder] = []
    @Published private(set) var scopedCount = 0
    /// bumped by ⌘F; the window opens its find bar when this changes
    @Published var findRequest = 0
    /// bumped by ⌃⌘H
    @Published var highlightRequest = 0
    /// nil = all PDFs, otherwise the path of an added folder
    @Published var scope: String? = UserDefaults.standard.string(forKey: "scope") {
        didSet {
            guard scope != oldValue else { return }
            UserDefaults.standard.set(scope, forKey: "scope")
            runSearchNow()
        }
    }

    private let writer: DB
    private let reader: DB
    private let writeQ = DispatchQueue(label: "pdfsearch.write", qos: .utility)
    private let readQ = DispatchQueue(label: "pdfsearch.read", qos: .userInitiated)
    private var searchGen = 0

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Search", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("index.sqlite").path
        let w = DB(path: file)
        let err = w.setup()
        writer = w
        reader = DB(path: file)
        errorMessage = err
        refresh()
    }

    // MARK: adding & updating

    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        panel.message = "Choose PDFs or folders to add to the index"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func add(_ urls: [URL]) {
        writeQ.async {
            var pdfs: [URL] = []
            for u in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    self.writer.addFolder(u.standardizedFileURL.path)
                    pdfs += Library.findPDFs(in: u)
                } else if u.pathExtension.lowercased() == "pdf" {
                    self.writer.unexclude(u.standardizedFileURL.path)
                    pdfs.append(u)
                }
            }
            self.index(pdfs)
        }
    }

    /// On launch (and ⌘R): drop deleted files, re-read changed ones, pick up new PDFs in added folders.
    func refresh() {
        writeQ.async {
            let fm = FileManager.default
            var urls: [URL] = []
            for (path, k) in self.writer.knownFiles() {
                if fm.fileExists(atPath: path) {
                    urls.append(URL(fileURLWithPath: path))
                } else if fm.fileExists(atPath: (path as NSString).deletingLastPathComponent) {
                    // only forget it if its folder is still there (so an unplugged drive doesn't wipe its PDFs)
                    self.writer.removeFile(id: k.id)
                }
            }
            for folder in self.writer.folders() where fm.fileExists(atPath: folder) {
                urls += Library.findPDFs(in: URL(fileURLWithPath: folder, isDirectory: true))
            }
            self.index(urls)
        }
    }

    func remove(_ ids: [Int]) {
        let paths = results.filter { ids.contains($0.id) }.map(\.path)
        writeQ.async {
            for p in paths { self.writer.exclude(p) }
            self.publishCount()
            DispatchQueue.main.async { self.runSearchNow() }
        }
    }

    func confirmClear() {
        let alert = NSAlert()
        alert.messageText = "Clear the whole index?"
        alert.informativeText = "Your PDFs aren't touched — PDF Search just forgets them. You can drag them in again any time."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        writeQ.async {
            self.writer.clear()
            self.publishCount()
            DispatchQueue.main.async { self.runSearchNow() }
        }
    }

    /// Runs on writeQ. Extracts text in parallel, writes serially.
    private func index(_ urls: [URL]) {
        let known = writer.knownFiles()
        let excluded = writer.excludedPaths()
        var seen = Set<String>()
        var todo: [(path: String, mtime: Double, size: Int)] = []
        for u in urls {
            let p = u.standardizedFileURL.path
            guard seen.insert(p).inserted, !excluded.contains(p),
                  let a = try? FileManager.default.attributesOfItem(atPath: p) else { continue }
            let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a[.size] as? NSNumber)?.intValue ?? 0
            if let k = known[p], abs(k.mtime - m) < 0.001, k.size == s { continue }
            todo.append((p, m, s))
        }
        publishCount()
        guard !todo.isEmpty else {
            DispatchQueue.main.async { self.progress = nil; self.runSearchNow() }
            return
        }
        let total = todo.count
        DispatchQueue.main.async { self.progress = (0, total) }

        let ops = OperationQueue()
        ops.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        let lock = NSLock()
        var done = 0
        for item in todo {
            ops.addOperation {
                let pages = autoreleasepool { Library.extract(URL(fileURLWithPath: item.path)) }
                lock.lock()
                self.writer.store(path: item.path, mtime: item.mtime, size: item.size, pages: pages)
                done += 1
                let d = done
                lock.unlock()
                if d % 5 == 0 || d == total {
                    DispatchQueue.main.async { self.progress = (d, total) }
                }
                if d % 100 == 0 {
                    let n = d
                    DispatchQueue.main.async { if n > 0 { self.runSearchNow() } }
                }
            }
        }
        ops.waitUntilAllOperationsAreFinished()
        publishCount()
        DispatchQueue.main.async { self.progress = nil; self.runSearchNow() }
    }

    private func publishCount() {
        let n = writer.count(scope: nil)
        let f = writer.folderList()
        DispatchQueue.main.async {
            self.docCount = n
            self.folders = f
            if let s = self.scope, !f.contains(where: { $0.path == s }) { self.scope = nil }
        }
    }

    func renameFolder(_ path: String) {
        let current = folders.first { $0.path == path }?.name ?? ""
        let alert = NSAlert()
        alert.messageText = "Rename folder"
        alert.informativeText = "This only changes the name shown in PDF Search, not the folder itself."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        writeQ.async {
            self.writer.renameFolder(path, to: name.isEmpty ? nil : name)
            self.publishCount()
        }
    }

    func removeFolder(_ path: String) {
        let name = folders.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
        let alert = NSAlert()
        alert.messageText = "Remove “\(name)” from PDF Search?"
        alert.informativeText = "Its PDFs stay exactly where they are — PDF Search just stops indexing them. You can drag the folder in again any time."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        writeQ.async {
            self.writer.removeFolder(path)
            self.publishCount()
            DispatchQueue.main.async { self.runSearchNow() }
        }
    }

    static func findPDFs(in dir: URL) -> [URL] {
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let u as URL in en where u.pathExtension.lowercased() == "pdf" { out.append(u) }
        return out
    }

    /// Text of every page, or nil if the PDF can't be opened.
    static func extract(_ url: URL) -> [String]? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var pages: [String] = []
        pages.reserveCapacity(doc.pageCount)
        for i in 0..<doc.pageCount { pages.append(doc.page(at: i)?.string ?? "") }
        return pages
    }

    // MARK: searching

    private func scheduleSearch() {
        searchGen += 1
        let g = searchGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if g == self.searchGen { self.runSearchNow() }
        }
    }

    func runSearchNow() {
        searchGen += 1
        let g = searchGen
        let q = query
        let scope = self.scope
        readQ.async {
            let (fts, terms) = Library.parse(q)
            let hits: [Hit]
            if q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hits = self.reader.allFiles(scope: scope)
            } else if fts.isEmpty {
                hits = []
            } else {
                hits = self.reader.search(fts, scope: scope)
            }
            let n = self.reader.count(scope: scope)
            DispatchQueue.main.async {
                guard g == self.searchGen else { return }
                self.results = hits
                self.scopedCount = n
                if self.terms != terms { self.terms = terms }
            }
        }
    }

    /// Plain words become prefix matches ("glitch" finds "glitches"); "quoted phrases" match exactly.
    /// All of them must appear on the same page.
    static func parse(_ q: String) -> (fts: String, terms: [String]) {
        var parts: [String] = []
        var terms: [String] = []
        let ns = q as NSString
        let re = try! NSRegularExpression(pattern: "\"([^\"]*)\"")
        let full = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: q, range: full) {
            let phrase = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            if hasWordChars(phrase) { parts.append("\"\(phrase)\""); terms.append(phrase) }
        }
        let rest = re.stringByReplacingMatches(in: q, range: full, withTemplate: " ")
            .replacingOccurrences(of: "\"", with: " ")
        for w in rest.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(w)
            if hasWordChars(word) { parts.append("\"\(word)\"*"); terms.append(word) }
        }
        return (parts.joined(separator: " "), terms)
    }

    private static func hasWordChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - SQLite (full-text index)

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let PAGE_SLOTS = 100_000  // fts rowid = fileID * PAGE_SLOTS + page  (page 0 = file name)

final class Stmt {
    let s: OpaquePointer
    init(_ s: OpaquePointer) { self.s = s }
    deinit { sqlite3_finalize(s) }

    func bind(_ args: [Any?]) {
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            if let v = a as? Int { sqlite3_bind_int64(s, idx, Int64(v)) }
            else if let v = a as? Double { sqlite3_bind_double(s, idx, v) }
            else if let v = a as? String { sqlite3_bind_text(s, idx, v, -1, SQLITE_TRANSIENT) }
            else { sqlite3_bind_null(s, idx) }
        }
    }
    @discardableResult func step() -> Bool { sqlite3_step(s) == SQLITE_ROW }
    func reset() { sqlite3_reset(s); sqlite3_clear_bindings(s) }
    func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    func double(_ i: Int32) -> Double { sqlite3_column_double(s, i) }
    func text(_ i: Int32) -> String {
        guard let c = sqlite3_column_text(s, i) else { return "" }
        return String(cString: c)
    }
}

final class DB {
    private var db: OpaquePointer?

    init(path: String) {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            db = nil
        }
        sqlite3_busy_timeout(db, 5000)
    }

    private var lastError: String { db == nil ? "can't open file" : String(cString: sqlite3_errmsg(db)) }

    @discardableResult private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }
    private func prepare(_ sql: String, _ args: [Any?] = []) -> Stmt? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s = s else { return nil }
        let st = Stmt(s)
        st.bind(args)
        return st
    }
    private func run(_ sql: String, _ args: [Any?] = []) { prepare(sql, args)?.step() }

    func setup() -> String? {
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        let ok = exec("""
            CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL,
                                             mtime REAL, size INTEGER, npages INTEGER, chars INTEGER);
            CREATE TABLE IF NOT EXISTS folders(path TEXT PRIMARY KEY, name TEXT);
            CREATE TABLE IF NOT EXISTS excluded(path TEXT PRIMARY KEY);
            CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(body, tokenize = 'unicode61 remove_diacritics 2');
            """)
        exec("ALTER TABLE folders ADD COLUMN name TEXT")  // older indexes; harmless if it already exists
        return ok ? nil : "Couldn't open the index: \(lastError)"
    }

    /// SQL + arguments that limit `files` to one added folder (byte-wise prefix range on the path).
    private func scopeFilter(_ scope: String?) -> (sql: String, args: [Any?]) {
        guard let s = scope else { return ("", []) }
        return (" AND files.path >= ? AND files.path < ?", [s + "/", s + "0"])
    }

    func folderList() -> [Folder] {
        var rows: [(String, String?)] = []
        if let st = prepare("SELECT path, name FROM folders") {
            while st.step() {
                let name = sqlite3_column_type(st.s, 1) == SQLITE_NULL ? nil : st.text(1)
                rows.append((st.text(0), name))
            }
        }
        return rows.map { path, name in
            Folder(path: path, name: name ?? DB.defaultName(path), count: count(scope: path))
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func defaultName(_ path: String) -> String {
        let last = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        if last.lowercased() == "storage" && parent.lowercased() == "zotero" { return "Zotero" }
        return last
    }

    func renameFolder(_ path: String, to name: String?) {
        run("UPDATE folders SET name=? WHERE path=?", [name, path])
    }

    func removeFolder(_ path: String) {
        let f = scopeFilter(path)
        var ids: [Int] = []
        if let st = prepare("SELECT id FROM files WHERE 1=1" + f.sql, f.args) {
            while st.step() { ids.append(st.int(0)) }
        }
        exec("BEGIN")
        for id in ids { removeFile(id: id) }
        run("DELETE FROM excluded WHERE path >= ? AND path < ?", [path + "/", path + "0"])
        run("DELETE FROM folders WHERE path=?", [path])
        exec("COMMIT")
    }

    // writing

    func store(path: String, mtime: Double, size: Int, pages: [String]?) {
        exec("BEGIN")
        if let old = prepare("SELECT id FROM files WHERE path=?", [path]), old.step() {
            removeFile(id: old.int(0))
        }
        let chars = pages?.reduce(0) { $0 + $1.utf16.count } ?? 0
        run("INSERT INTO files(path, mtime, size, npages, chars) VALUES (?,?,?,?,?)",
            [path, mtime, size, pages?.count ?? -1, chars])
        let id = Int(sqlite3_last_insert_rowid(db))
        if let ins = prepare("INSERT INTO fts(rowid, body) VALUES (?,?)") {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " ")
            ins.bind([id * PAGE_SLOTS, name]); ins.step(); ins.reset()
            for (i, text) in (pages ?? []).enumerated() where i + 1 < PAGE_SLOTS {
                guard text.contains(where: { !$0.isWhitespace }) else { continue }
                ins.bind([id * PAGE_SLOTS + i + 1, text]); ins.step(); ins.reset()
            }
        }
        exec("COMMIT")
    }

    func removeFile(id: Int) {
        run("DELETE FROM fts WHERE rowid BETWEEN ? AND ?", [id * PAGE_SLOTS, id * PAGE_SLOTS + PAGE_SLOTS - 1])
        run("DELETE FROM files WHERE id=?", [id])
    }

    func exclude(_ path: String) {
        exec("BEGIN")
        if let st = prepare("SELECT id FROM files WHERE path=?", [path]), st.step() { removeFile(id: st.int(0)) }
        run("INSERT OR IGNORE INTO excluded(path) VALUES (?)", [path])
        exec("COMMIT")
    }
    func unexclude(_ path: String) { run("DELETE FROM excluded WHERE path=?", [path]) }
    func addFolder(_ path: String) { run("INSERT OR IGNORE INTO folders(path) VALUES (?)", [path]) }

    func clear() {
        exec("DELETE FROM fts; DELETE FROM files; DELETE FROM folders; DELETE FROM excluded; VACUUM;")
    }

    // reading

    func knownFiles() -> [String: (id: Int, mtime: Double, size: Int)] {
        var out: [String: (id: Int, mtime: Double, size: Int)] = [:]
        guard let st = prepare("SELECT id, path, mtime, size FROM files") else { return out }
        while st.step() { out[st.text(1)] = (st.int(0), st.double(2), st.int(3)) }
        return out
    }

    func folders() -> [String] {
        var out: [String] = []
        guard let st = prepare("SELECT path FROM folders") else { return out }
        while st.step() { out.append(st.text(0)) }
        return out
    }

    func excludedPaths() -> Set<String> {
        var out = Set<String>()
        guard let st = prepare("SELECT path FROM excluded") else { return out }
        while st.step() { out.insert(st.text(0)) }
        return out
    }

    func count(scope: String?) -> Int {
        let f = scopeFilter(scope)
        guard let st = prepare("SELECT count(*) FROM files WHERE 1=1" + f.sql, f.args), st.step() else { return 0 }
        return st.int(0)
    }

    func allFiles(scope: String?) -> [Hit] {
        var out: [Hit] = []
        let f = scopeFilter(scope)
        guard let st = prepare("SELECT id, path, npages, chars FROM files WHERE 1=1" + f.sql, f.args) else { return out }
        while st.step() {
            let n = st.int(2), chars = st.int(3)
            let badge = n < 0 ? "can't read" : (chars < 50 ? "no text" : (n == 1 ? "1 page" : "\(n) pages"))
            out.append(Hit(id: st.int(0), path: st.text(1), page: 0, badge: badge, snippet: nil))
        }
        return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func search(_ query: String, scope: String?) -> [Hit] {
        let f = scopeFilter(scope)
        guard let st = prepare("""
            SELECT fts.rowid, files.path, snippet(fts, 0, char(2), char(3), '…', 14), bm25(fts)
            FROM fts JOIN files ON files.id = fts.rowid / \(PAGE_SLOTS)
            WHERE fts MATCH ?\(f.sql)
            ORDER BY bm25(fts)
            LIMIT 5000
            """, ([query] as [Any?]) + f.args) else { return [] }

        struct Acc { var path: String; var score: Double; var pages: Int; var page: Int; var snippet: String }
        var acc: [Int: Acc] = [:]
        while st.step() {
            let rowid = st.int(0)
            let fid = rowid / PAGE_SLOTS, page = rowid % PAGE_SLOTS
            let score = st.double(3)
            if var a = acc[fid] {
                a.score += score
                if page > 0 { a.pages += 1 }
                if a.page == 0 && page > 0 { a.page = page; a.snippet = st.text(2) }
                acc[fid] = a
            } else {
                acc[fid] = Acc(path: st.text(1), score: score, pages: page > 0 ? 1 : 0, page: page, snippet: st.text(2))
            }
        }
        return acc.sorted { $0.value.score < $1.value.score }.map { fid, a in
            let badge = a.pages == 0 ? "in name" : (a.pages == 1 ? "1 page" : "\(a.pages) pages")
            return Hit(id: fid, path: a.path, page: a.page, badge: badge, snippet: DB.highlight(a.snippet))
        }
    }

    /// Snippet text with \u{2}…\u{3} around matches → bold, tinted text.
    static func highlight(_ raw: String) -> AttributedString {
        let s = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        var out = AttributedString()
        var bold = false
        var cur = ""
        func flush() {
            guard !cur.isEmpty else { return }
            var piece = AttributedString(cur)
            if bold {
                piece.font = Font.callout.bold()
                piece.foregroundColor = Color.primary
                piece.backgroundColor = Color.yellow.opacity(0.35)
            }
            out += piece
            cur = ""
        }
        for ch in s {
            if ch == "\u{2}" { flush(); bold = true }
            else if ch == "\u{3}" { flush(); bold = false }
            else { cur.append(ch) }
        }
        flush()
        return out
    }
}
