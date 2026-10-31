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

    init() {
        // `PDFSearch --selftest` checks the bibliography code and exits (run by build.sh)
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
    }

    var body: some Scene {
        Window("PDF Search", id: "main") {
            ContentView()
                .environmentObject(lib)
                .frame(minWidth: 820, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Paper (PDF)…") { lib.choosePapers() }
                    .keyboardShortcut("o")
                Button("Add Book or Chapter…") { lib.requestAdd([nil]) }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Add Folder to Search…") { lib.choose() }
                Divider()
                Button("Rescan Folders") { lib.refresh() }
                    .keyboardShortcut("r")
                Button("Write Notes for All Annotated PDFs") { lib.exportAllMarginalia() }
                Button("Clear Index…") { lib.confirmClear() }
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in This PDF…") { lib.findRequest += 1 }
                    .keyboardShortcut("f")
                Button("Highlight Selection (or press H)") { lib.noteRequest += 1 }
                    .keyboardShortcut("h", modifiers: [.command, .control])
                Divider()
                Button("Copy Citation [@key]") { lib.citeRequest += 1 }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Copy LaTeX Citation \\cite{key}") { lib.citeTexRequest += 1 }
                    .keyboardShortcut("c", modifiers: [.command, .shift, .option])
            }
        }
        Settings {
            SettingsView().environmentObject(lib)
        }
    }
}

/// PDF Search ▸ Settings (⌘,): where papers, library.bib and notes live.
struct SettingsView: View {
    @EnvironmentObject var lib: Library
    @State private var papers = Paths.papers
    @State private var bib = Paths.libraryBib
    @State private var notes = Paths.notesFolder
    @State private var collections = Paths.collectionsFolder
    @AppStorage("writeNotes") private var writeNotes = true

    var body: some View {
        Form {
            row("Papers folder", papers, help: "Searched automatically. New papers go in its Library folder.") { path in
                set("papersFolder", path); papers = Paths.papers; lib.refresh()
            } reset: { set("papersFolder", nil); papers = Paths.papers; lib.refresh() }
            row("library.bib in", (bib as NSString).deletingLastPathComponent,
                help: "Your bibliography. Point Overleaf, Pandoc or Obsidian at this file.") { path in
                set("libraryBib", path + "/library.bib"); bib = Paths.libraryBib; lib.reloadBib(force: true)
            } reset: { set("libraryBib", nil); bib = Paths.libraryBib; lib.reloadBib(force: true) }
            Toggle("Write a Markdown note for each paper I annotate", isOn: $writeNotes)
            row("Notes folder", notes, help: "Plain Markdown files (@key.md): any notes app can open them. Obsidian users: a folder inside your vault.") { path in
                set("notesFolder", path); notes = Paths.notesFolder
            } reset: { set("notesFolder", nil); notes = Paths.notesFolder }
                .disabled(!writeNotes)
            row("Collections folder", collections, help: "One Markdown note per collection, listing its papers as [[@key]] lines.") { path in
                set("collectionsFolder", path); collections = Paths.collectionsFolder; lib.reloadCollections()
            } reset: { set("collectionsFolder", nil); collections = Paths.collectionsFolder; lib.reloadCollections() }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func set(_ key: String, _ value: String?) {
        if let v = value { UserDefaults.standard.set(v, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func row(_ label: String, _ path: String, help: String,
                     choose: @escaping (String) -> Void, reset: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).frame(width: 110, alignment: .leading)
                Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url { choose(url.standardizedFileURL.path) }
                }
                Button("Default") { reset() }
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // PDFs or folders dropped on the Dock icon
    func application(_ application: NSApplication, open urls: [URL]) { Library.shared.handle(urls) }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var lib: Library
    @StateObject private var viewer = Viewer()
    @State private var selection: Int?
    @State private var dropTargeted = false
    @State private var showFind = false
    @AppStorage("showMargin") private var showMargin = true
    /// a library entry with no PDF (e.g. a book), shown as a card instead of a PDF
    @State private var entryOnly: BibEntry?
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
        .onChange(of: lib.citeRequest) { _ in cite(.pandoc) }
        .onChange(of: lib.noteRequest) { _ in
            showMargin = true
            viewer.highlightAndComment()
        }
        .onChange(of: viewer.focusNoteID) { id in if id != nil { showMargin = true } }
        .onChange(of: lib.linkRequest) { req in
            guard let req = req else { return }
            entryOnly = nil
            viewer.show(path: req.path, terms: [], page: req.page)
        }
        .onOpenURL { url in lib.handle([url]) }
        .sheet(item: $lib.addRequest, onDismiss: { lib.nextAdd() }) { req in
            AddPaperView(file: req.file).environmentObject(lib)
        }
        .onChange(of: lib.citeTexRequest) { _ in cite(.latex) }
        .task(id: findText) {
            guard showFind else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let p = viewer.path else { return }
            viewer.show(path: p, terms: activeTerms, page: 0, wholeWords: !findMode)
        }
    }

    // Sidebar: results list + status line
    var searchPrompt: String {
        if let c = scopeCollection { return "Search \(c.name)" }
        if let s = lib.scope, let f = lib.folders.first(where: { $0.path == s }) { return "Search \(f.name)" }
        return "Search everything"
    }
    var scopeFolder: Folder? { lib.scope.flatMap { s in lib.folders.first { $0.path == s } } }
    var scopeCollection: Collection? { lib.scope.flatMap { s in lib.collections.first { $0.path == s } } }

    /// the entry behind the first selected result
    func entryFor(_ ids: Set<Int>) -> BibEntry? {
        guard let id = ids.first, let h = lib.results.first(where: { $0.id == id }) else { return nil }
        return h.entry ?? (h.path.isEmpty ? nil : lib.bib.entry(forPath: h.path))
    }

    var scopeBar: some View {
        HStack(spacing: 6) {
            Picker("Search in", selection: $lib.scope) {
                Text("Everything (\(lib.docCount))").tag(String?.none)
                Divider()
                ForEach(lib.folders) { f in
                    Text(verbatim: String(repeating: "\u{2003}", count: f.depth) + "\(f.name)  (\(f.count))")
                        .tag(Optional(f.path))
                }
                if !lib.collections.isEmpty {
                    Divider()
                    ForEach(lib.collections) { c in
                        Label("\(c.name)  (\(c.keys.count))", systemImage: "books.vertical")
                            .tag(Optional(c.path))
                    }
                }
            }
            .pickerStyle(.menu)
            Menu {
                if let c = scopeCollection {
                    Button("Make Bibliography (.bib)") { lib.makeBibliography(c) }
                    Button("Open Collection Note") { NSWorkspace.shared.open(URL(fileURLWithPath: c.path)) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: c.path)]) }
                }
                if let f = scopeFolder {
                    if f.isRoot { Button("Rename…") { lib.renameFolder(f.path) } }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                    if f.isRoot {
                        Divider()
                        Button("Remove Folder from Index…") { lib.removeFolder(f.path) }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(lib.scope == nil)
            .help("Folder or collection options")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    var sidebar: some View {
        VStack(spacing: 0) {
            if !lib.folders.isEmpty || !lib.collections.isEmpty {
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
                    Button("Copy Citation [@key]") { citeHit(ids, .pandoc) }
                    Button("Copy LaTeX Citation \\cite{key}") { citeHit(ids, .latex) }
                    CollectionMenu(target: { entryFor(ids) })
                    if let c = scopeCollection, let e = entryFor(ids) {
                        Button("Remove from “\(c.name)”") { lib.removeFromCollection(e.key, c) }
                    }
                    Divider()
                    if let id = ids.first, let h = lib.results.first(where: { $0.id == id }), !h.path.isEmpty, h.entry == nil {
                        Button("Look Up Citation Details…") { lib.requestAdd([URL(fileURLWithPath: h.path)]) }
                    }
                    Button("Open in Preview") { openFiles(ids) }
                    Button("Show in Finder") { reveal(ids) }
                    Divider()
                    Button("Remove from Index") { lib.remove(Array(ids).filter { $0 > 0 }) }
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
                Menu {
                    Button("Add Paper (PDF)…") { lib.choosePapers() }
                    Button("Add Book or Chapter…") { lib.requestAdd([nil]) }
                    Divider()
                    Button("Add Folder to Search…") { lib.choose() }
                } label: { Label("Add", systemImage: "plus") }
                    .help("Add a paper, a book, or a folder to search (or drag a PDF into the window)")
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
            Button("Choose a Folder…") { lib.choose() }
                .padding(.top, 4)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var statusBar: some View {
        HStack(spacing: 8) {
            if let f = lib.flash {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(f).foregroundStyle(.primary).lineLimit(1)
            } else if let p = lib.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 70)
                Text("Indexing \(p.done) of \(p.total)…")
            } else if let err = lib.errorMessage {
                Text(err).foregroundStyle(.red)
            } else if lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(lib.results.count) items")
            } else {
                Text("\(lib.results.count) matches")
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
        HStack(spacing: 0) {
            pdfPane
            if showMargin && viewer.path != nil && entryOnly == nil {
                Divider()
                MarginColumn(viewer: viewer)
                    .frame(width: 290)
            }
        }
    }

    var pdfPane: some View {
        PDFKitView(view: viewer.pdfView)
            .overlay {
                if let e = entryOnly {
                    EntryCard(entry: e, cite: { cite($0) })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                } else if viewer.path == nil {
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
            .navigationTitle(entryOnly?.shortCite ?? currentEntry?.shortCite ?? viewer.title)
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("Copy [@key] for Obsidian / Markdown") { cite(.pandoc) }
                        Button("Copy \\cite{key} for LaTeX / Overleaf") { cite(.latex) }
                        Button("Copy Key Only") { cite(.key) }
                    } label: {
                        Label("Cite", systemImage: "quote.opening")
                    } primaryAction: {
                        cite(.pandoc)
                    }
                        .disabled(viewer.path == nil && entryOnly == nil)
                        .help("Copy citation (⇧⌘C for [@key], ⌥⇧⌘C for \\cite{key})")
                    CollectionMenu(target: { currentEntry })
                        .disabled(viewer.path == nil && entryOnly == nil)
                        .help("Add this paper to a collection (a reading list for something you're writing)")
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
                    Toggle(isOn: $showMargin) {
                        Label("Notes", systemImage: "sidebar.right")
                    }
                        .toggleStyle(.button)
                        .help("Show or hide your highlights and notes")
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
        if hit.path.isEmpty {
            entryOnly = hit.entry
            viewer.close()
        } else {
            entryOnly = nil
            viewer.show(path: hit.path, terms: activeTerms, page: hit.page, wholeWords: !findMode)
        }
    }

    /// the bibliography entry for whatever is on screen
    var currentEntry: BibEntry? {
        if let e = entryOnly { return e }
        return viewer.path.flatMap { lib.bib.entry(forPath: $0) }
    }

    func cite(_ style: CiteStyle) {
        if let e = entryOnly { lib.cite(entry: e, path: nil, style: style) }
        else if let p = viewer.path { lib.cite(entry: lib.bib.entry(forPath: p), path: p, style: style) }
    }

    func citeHit(_ ids: Set<Int>, _ style: CiteStyle) {
        guard let id = ids.first, let h = lib.results.first(where: { $0.id == id }) else { return }
        lib.cite(entry: h.entry, path: h.path.isEmpty ? nil : h.path, style: style)
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
        lib.results.filter { ids.contains($0.id) && !$0.path.isEmpty }.map { URL(fileURLWithPath: $0.path) }
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
        group.notify(queue: .main) { lib.handleDropped(urls) }
    }
}

struct HitRow: View {
    let hit: Hit
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(hit.displayTitle).font(.headline).lineLimit(2)
                Spacer(minLength: 6)
                Text(hit.badge).font(.caption).foregroundStyle(.secondary)
            }
            if let e = hit.entry {
                HStack(spacing: 6) {
                    Text(e.shortCite).font(.subheadline)
                    if e.inLibrary {
                        Text("@" + e.key).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
            }
            if let s = hit.snippet {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if !hit.path.isEmpty {
                Text(hit.folder).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
    }
}

/// "Add to Collection ▸ <collections> / New Collection…" for one paper or book.
struct CollectionMenu: View {
    @EnvironmentObject var lib: Library
    let target: () -> BibEntry?
    var body: some View {
        Menu {
            ForEach(lib.collections) { c in
                Button(c.name) { lib.addToCollection(target(), c) }
            }
            if !lib.collections.isEmpty { Divider() }
            Button("New Collection…") { lib.newCollection(adding: target()) }
        } label: {
            Label("Add to Collection", systemImage: "text.badge.plus")
        }
    }
}

/// Shown instead of a PDF for library entries without one (books you don't have as PDFs, etc.).
struct EntryCard: View {
    let entry: BibEntry
    let cite: (CiteStyle) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.kindLabel.uppercased() + " · NO PDF")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(entry.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            if !entry.people.isEmpty {
                Text((entry.fields["author"] == nil ? "Edited by " : "") + entry.people.joined(separator: "; "))
                    .font(.title3).textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(["booktitle", "journal", "publisher", "address", "year", "pages", "edition", "isbn", "doi", "url"], id: \.self) { k in
                    if let v = entry.fields[k], !v.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(k.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
                                .frame(width: 80, alignment: .trailing)
                            Text(v).textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.top, 4)
            HStack(spacing: 8) {
                Button("Copy [@\(entry.key)]") { cite(.pandoc) }
                Button("Copy \\cite{\(entry.key)}") { cite(.latex) }
                CollectionMenu(target: { entry }).fixedSize()
            }
            .padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: 560, alignment: .leading)
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
    var onHighlightAndNote: ((PDFSelection) -> Void)?
    var onRemove: ((PDFAnnotation) -> Void)?
    var onEditNote: ((PDFAnnotation) -> Void)?

    static func isHighlight(_ a: PDFAnnotation) -> Bool {
        (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Highlight"
    }

    /// H (no modifier keys) highlights the selected text.
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "h",
           let sel = currentSelection, let t = sel.string, t.contains(where: { !$0.isWhitespace }) {
            onHighlightAndNote?(sel)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var extra: [NSMenuItem] = []
        if let sel = currentSelection, let text = sel.string, text.contains(where: { !$0.isWhitespace }) {
            let note = NSMenuItem(title: "Highlight", action: #selector(noteSelectionItem(_:)), keyEquivalent: "")
            note.target = self
            extra.append(note)
        }
        let pt = convert(event.locationInWindow, from: nil)
        if let page = page(for: pt, nearest: false) {
            let pagePoint = convert(pt, to: page)
            if let ann = page.annotation(at: pagePoint), Marginalia.isMarkup(ann) {
                let edit = NSMenuItem(title: (ann.contents ?? "").isEmpty ? "Add a Note" : "Edit Note",
                                      action: #selector(editNoteItem(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = ann
                extra.append(edit)
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
    @objc private func noteSelectionItem(_ sender: NSMenuItem) {
        if let sel = currentSelection { onHighlightAndNote?(sel) }
    }
    @objc private func editNoteItem(_ sender: NSMenuItem) {
        if let ann = sender.representedObject as? PDFAnnotation { onEditNote?(ann) }
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

    @Published var highlightColor: HighlightColor =
        HighlightColor(rawValue: UserDefaults.standard.string(forKey: "highlightColor") ?? "") ?? .yellow {
        didSet { UserDefaults.standard.set(highlightColor.rawValue, forKey: "highlightColor") }
    }
    private var unsaved = false
    private var saveWork: DispatchWorkItem?
    /// highlights / notes in the open PDF, in page order (shown in the margin column)
    @Published private(set) var notes: [MarginNote] = []
    /// the note card to scroll to and put the cursor in
    @Published var focusNoteID: ObjectIdentifier?
    /// true while text is selected in the PDF (shows the Highlight button)
    @Published private(set) var hasSelection = false
    /// notes about the whole paper (stored in the PDF as a page-1 note starting with "Summary")
    @Published private(set) var summary = ""
    /// bumped each time a document finishes loading (resets the summary box)
    @Published private(set) var docGen = 0

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
        pdfView.onHighlightAndNote = { [weak self] _ in self?.highlightAndComment() }
        pdfView.onRemove = { [weak self] ann in self?.removeHighlight(ann) }
        pdfView.onEditNote = { [weak self] ann in
            self?.refreshNotes()
            self?.focusNoteID = ObjectIdentifier(ann)
        }
        observers.append(nc.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            let t = self.pdfView.currentSelection?.string ?? ""
            let has = t.contains(where: { !$0.isWhitespace })
            if has != self.hasSelection { self.hasSelection = has }
        })
        // Clicking a highlight in the PDF selects its note card.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self, event.window === self.pdfView.window else { return event }
            let p = self.pdfView.convert(event.locationInWindow, from: nil)
            guard self.pdfView.bounds.contains(p), event.clickCount == 1,
                  let page = self.pdfView.page(for: p, nearest: false) else { return event }
            let pagePoint = self.pdfView.convert(p, to: page)
            DispatchQueue.main.async {
                guard !self.hasSelection,
                      let ann = page.annotations.last(where: { Marginalia.isMarkup($0) && $0.bounds.contains(pagePoint) })
                else { return }
                self.focusNoteID = ObjectIdentifier(ann)
            }
            return event
        }
    }

    // MARK: highlights (saved into the PDF file, like Preview)

    /// H, the Highlight button or ⌃⌘H: highlight the selected text and put the cursor in its note.
    func highlightAndComment() {
        guard let sel = pdfView.currentSelection, let text = sel.string, text.contains(where: { !$0.isWhitespace }) else {
            Library.shared.showFlash("Select some text in the PDF first, then press H")
            return
        }
        let made = addHighlight(sel)
        hasSelection = false
        if let a = made.first { focusNoteID = ObjectIdentifier(a) }
    }

    /// Store a note in its highlight (the PDF's own comment field, so every PDF app shows it).
    /// Called as you type; the PDF is saved a moment after you stop.
    func updateComment(_ note: MarginNote, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (note.annotation.contents ?? "") != t else { return }
        note.annotation.contents = t
        note.annotation.modificationDate = Date()
        markUnsaved(after: 1.5)
    }

    /// "About this paper": kept in a note on page 1 of the PDF; removed when emptied.
    func updateSummary(_ text: String) {
        guard let doc = pdfView.document, let page = doc.page(at: 0) else { return }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = Marginalia.summaryAnnotation(doc)
        if t.isEmpty {
            guard let a = existing else { return }
            page.removeAnnotation(a)
        } else {
            let contents = Marginalia.summaryHeading + "\n" + t
            if let a = existing {
                guard a.contents != contents else { return }
                a.contents = contents
                a.modificationDate = Date()
            } else {
                let box = page.bounds(for: .cropBox)
                let a = PDFAnnotation(bounds: CGRect(x: box.minX + 8, y: box.maxY - 28, width: 20, height: 20),
                                      forType: .text, withProperties: nil)
                a.contents = contents
                a.color = .systemYellow
                a.userName = NSFullUserName()
                a.modificationDate = Date()
                page.addAnnotation(a)
            }
        }
        summary = t
        markUnsaved(after: 1.5)
    }

    func setHighlightColor(_ c: HighlightColor) {
        highlightColor = c
    }

    func reveal(_ note: MarginNote) {
        guard let page = note.annotation.page else { return }
        pdfView.go(to: note.annotation.bounds.insetBy(dx: -40, dy: -80), on: page)
    }

    func refreshNotes() {
        notes = pdfView.document.map(Marginalia.collect) ?? []
    }

    @discardableResult
    func addHighlight(_ sel: PDFSelection) -> [PDFAnnotation] {
        guard pdfView.document != nil else { return [] }
        var made: [PDFAnnotation] = []
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
            made.append(ann)
        }
        pdfView.clearSelection()
        markUnsaved()
        refreshNotes()
        return made
    }

    func removeHighlight(_ ann: PDFAnnotation) {
        ann.page?.removeAnnotation(ann)
        markUnsaved()
        refreshNotes()
    }

    private func markUnsaved(after delay: Double = 0.8) {
        unsaved = true
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
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
        if ok { Library.shared.afterSave(path: url.path, notes: Marginalia.collect(doc), summary: Marginalia.summary(doc)) }
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
                self.focusNoteID = nil
                self.hasSelection = false
                self.refreshNotes()
                self.summary = doc.map(Marginalia.summary) ?? ""
                self.docGen += 1
                if !sels.isEmpty {
                    self.focus(0)
                } else if let doc = doc {
                    let idx = page > 0 ? page - 1 : (keepPage ?? 0)
                    if let p = doc.page(at: min(idx, max(doc.pageCount - 1, 0))) { self.pdfView.go(to: p) }
                }
            }
        }
    }

    func step(_ delta: Int) { focus(matchIndex + delta) }

    /// Show nothing (used when a library entry without a PDF is selected).
    func close() {
        flushSave()
        gen += 1
        pdfView.highlightedSelections = nil
        pdfView.document = nil
        selections = []
        notes = []
        summary = ""
        docGen += 1
        focusNoteID = nil
        hasSelection = false
        path = nil
        missing = false
        matchCount = 0
        matchIndex = 0
        title = "PDF Search"
    }

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

/// Where the library lives. Defaults work with or without Obsidian; change them in Settings (⌘,).
enum Paths {
    static func setting(_ key: String) -> String? {
        let v = UserDefaults.standard.string(forKey: key)
        return (v?.isEmpty ?? true) ? nil : v
    }
    /// ~/Obsidian Vault, if there is one
    static var vault: String? {
        let v = NSHomeDirectory() + "/Obsidian Vault"
        return FileManager.default.fileExists(atPath: v) ? v : nil
    }
    static var papers: String { setting("papersFolder") ?? NSHomeDirectory() + "/Papers" }
    static var libraryFolder: String { papers + "/Library" }
    static var libraryBib: String { setting("libraryBib") ?? (vault.map { $0 + "/library.bib" } ?? papers + "/library.bib") }
    static var notesFolder: String { setting("notesFolder") ?? (vault.map { $0 + "/Literature" } ?? papers + "/Notes") }
    static var collectionsFolder: String { setting("collectionsFolder") ?? (vault.map { $0 + "/Collections" } ?? papers + "/Collections") }
    /// write a Markdown note (@key.md) for each annotated paper
    static var writeNotes: Bool { UserDefaults.standard.object(forKey: "writeNotes") as? Bool ?? true }
}

enum CiteStyle { case pandoc, latex, key }

struct AddRequest: Identifiable {
    let id = UUID()
    let file: URL?
}

struct LinkRequest: Equatable {
    let path: String
    let page: Int
    let n: Int
}

struct Hit: Identifiable {
    let id: Int                 // file id; negative for library entries without a PDF
    let path: String            // "" for entries without a PDF
    let page: Int
    let badge: String
    let snippet: AttributedString?
    var entry: BibEntry? = nil
    var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
    var displayTitle: String {
        if let t = entry?.title, !t.isEmpty { return t }
        return path.isEmpty ? (entry?.key ?? "") : name
    }
    var sortKey: String {
        guard let e = entry else { return name }
        return (e.people.first.map(BibEntry.lastName) ?? "") + " " + e.year + " " + e.title
    }
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
    var depth = 0          // 0 = a folder you added; 1–2 = folders inside it
    var isRoot = true
    var id: String { path }
}

/// A collection: a Markdown note listing papers for something you're writing. Any `@key` in the
/// file counts (e.g. `- [[@cascone2000aesthetics]] Cascone (2000) The Aesthetics of Failure`).
struct Collection: Identifiable, Equatable {
    let name: String
    let path: String
    let keys: [String]
    var id: String { path }
    var keySet: Set<String> { Set(keys) }

    private static let keyPattern = try! NSRegularExpression(
        pattern: "(?<![A-Za-z0-9_.])@([A-Za-z0-9_](?:[A-Za-z0-9_:.\\-]*[A-Za-z0-9_])?)")

    /// every @key in the text, in order, without repeats
    static func keys(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in keyPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            if seen.insert(k).inserted { out.append(k) }
        }
        return out
    }
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
    /// bumped by ⇧⌘C / ⌥⇧⌘C
    @Published var citeRequest = 0
    @Published var citeTexRequest = 0
    /// bumped by Edit ▸ Highlight Selection (⌃⌘H)
    @Published var noteRequest = 0
    /// a pdfsearch://open?file=…&page=… link to show (from an Obsidian note)
    @Published private(set) var linkRequest: LinkRequest?
    private var lastLinkTime = Date.distantPast
    /// everything in library.bib and any reference .bib files (e.g. a conference archive's)
    @Published private(set) var bib = BibIndex()
    /// the "Add to Library" card being shown (nil file = a book or chapter without a PDF)
    @Published var addRequest: AddRequest?
    private var addQueue: [URL?] = []
    /// Markdown collections in Paths.collectionsFolder
    @Published private(set) var collections: [Collection] = []
    /// short confirmation shown in the status bar ("Copied [@key]")
    @Published private(set) var flash: String?
    private var flashGen = 0
    private let bibQ = DispatchQueue(label: "pdfsearch.bib", qos: .userInitiated)
    private var bibStamp: [String: Date] = [:]          // only touched on bibQ
    private var bibForIndex = BibIndex()                  // only touched on writeQ
    private var indexedPaths = Set<String>()              // NFC paths of indexed PDFs (main thread)
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
        // pick up edits to library.bib (or new reference .bib files) whenever the app comes to the front
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadBib()
            self?.reloadCollections()
        }
        reloadCollections()
    }

    // MARK: collections

    func reloadCollections() {
        let dir = Paths.collectionsFolder
        var out: [Collection] = []
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        where f.lowercased().hasSuffix(".md") && !f.hasPrefix(".") {
            let path = dir + "/" + f
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            out.append(Collection(name: (f as NSString).deletingPathExtension, path: path, keys: Collection.keys(in: text)))
        }
        out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard out != collections else { return }
        collections = out
        if let s = scope, out.contains(where: { $0.path == s }) { runSearchNow() }
    }

    private func noDetailsAlert() {
        let alert = NSAlert()
        alert.messageText = "No citation details for this PDF yet"
        alert.informativeText = "PDF Search only knows the details of items in your library.bib (and reference .bib files inside your Papers folders). Add an entry for it to library.bib, and name the PDF after its key."
        alert.runModal()
    }

    /// Append "- [[@key]] Author (Year) Title" to a collection's note.
    func addToCollection(_ entry: BibEntry?, _ c: Collection) {
        guard let e0 = entry else { noDetailsAlert(); return }
        guard let e = ensureInLibrary(e0)?.entry else { return }
        if c.keys.contains(e.key) { showFlash("Already in \(c.name)"); return }
        var text = (try? String(contentsOfFile: c.path, encoding: .utf8)) ?? "# \(c.name)\n\n"
        if !text.hasSuffix("\n") { text += "\n" }
        text += "- [[@\(e.key)]] \(e.shortCite) \(e.title)\n"
        do {
            try text.write(toFile: c.path, atomically: true, encoding: .utf8)
            reloadCollections()
            showFlash("Added \(e.shortCite) to \(c.name)")
        } catch {
            showFlash("Couldn't write \(c.name).md: \(error.localizedDescription)")
        }
    }

    /// Ask for a name, create <name>.md, and optionally add a first item.
    func newCollection(adding entry: BibEntry?) {
        let dir = Paths.collectionsFolder
        let alert = NSAlert()
        alert.messageText = "New collection"
        alert.informativeText = "A collection is a list of papers and books for something you're writing. It's saved as a Markdown note in \(dir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "e.g. Glitch Aesthetics paper"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty else { return }
        let path = dir + "/" + name + ".md"
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                try "# \(name)\n\nPapers and books for this project, one per line. PDF Search adds lines here; edit, reorder or comment on them freely.\n\n"
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        } catch {
            showFlash("Couldn't create the collection: \(error.localizedDescription)")
            return
        }
        reloadCollections()
        if let e = entry, let c = collections.first(where: { $0.path == path }) { addToCollection(e, c) }
        else { showFlash("Created collection \(name)") }
    }

    /// Delete the line(s) that mention @key from a collection's note.
    func removeFromCollection(_ key: String, _ c: Collection) {
        guard let text = try? String(contentsOfFile: c.path, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { !Collection.keys(in: $0).contains(key) }
        do {
            try kept.joined(separator: "\n").write(toFile: c.path, atomically: true, encoding: .utf8)
            reloadCollections()
            showFlash("Removed from \(c.name)")
        } catch {
            showFlash("Couldn't write \(c.name).md: \(error.localizedDescription)")
        }
    }

    /// Write <collection>.bib next to the note, with just its entries (for Overleaf, Pandoc…).
    func makeBibliography(_ c: Collection) {
        var out = "% Bibliography for \(c.name), made by PDF Search from \(c.name).md\n\n"
        var n = 0
        var missing: [String] = []
        for k in c.keys {
            guard let e = bib.entries.first(where: { $0.inLibrary && $0.key == k }) else { missing.append(k); continue }
            var fields = e.raw
            fields["file"] = nil
            out += BibWriter.format(type: e.type, key: e.key, fields: fields, file: nil) + "\n"
            n += 1
        }
        let path = (c.path as NSString).deletingPathExtension + ".bib"
        do {
            try out.write(toFile: path, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            showFlash("Wrote \(c.name).bib with \(n) entries" + (missing.isEmpty ? "" : " (not in library.bib: " + missing.joined(separator: ", ") + ")"))
        } catch {
            showFlash("Couldn't write \(c.name).bib: \(error.localizedDescription)")
        }
    }

    // MARK: bibliography

    /// Re-read library.bib plus any .bib file in an added folder or the folders directly inside it.
    func reloadBib(force: Bool = false) {
        let roots = Array(Set(folders.filter { $0.isRoot }.map(\.path) + [Paths.papers]))
        let libPath = Paths.libraryBib
        let collectionsDir = Paths.collectionsFolder
        bibQ.async {
            let fm = FileManager.default
            var files: [(path: String, isLibrary: Bool)] = [(libPath, true)]
            for root in roots {
                var dirs = [root]
                for k in (try? fm.contentsOfDirectory(atPath: root)) ?? [] where !k.hasPrefix(".") {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: root + "/" + k, isDirectory: &isDir), isDir.boolValue { dirs.append(root + "/" + k) }
                }
                for d in dirs {
                    if d == collectionsDir { continue }
                    for f in (try? fm.contentsOfDirectory(atPath: d)) ?? [] where f.lowercased().hasSuffix(".bib") {
                        let p = d + "/" + f
                        if p != libPath && !files.contains(where: { $0.path == p }) { files.append((p, false)) }
                    }
                }
            }
            var stamp: [String: Date] = [:]
            for f in files {
                stamp[f.path] = ((try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date) ?? .distantPast
            }
            guard force || stamp != self.bibStamp else { return }
            self.bibStamp = stamp
            var all: [BibEntry] = []
            for f in files {
                guard let data = fm.contents(atPath: f.path) else { continue }
                let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                all += BibParser.parse(text, inLibrary: f.isLibrary)
            }
            let index = BibIndex(entries: all)
            DispatchQueue.main.async {
                self.bib = index
                self.runSearchNow()
            }
            self.writeQ.async {
                self.bibForIndex = index
                self.applyBibToIndex(index)
            }
        }
    }

    /// Make PDFs findable by their title, authors, year and citation key (the "page 0" row of each file).
    private func applyBibToIndex(_ bib: BibIndex) {
        var rows: [(Int, String)] = []
        for (path, k) in writer.knownFiles() {
            guard let e = bib.entry(forPath: path) else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                .replacingOccurrences(of: "_", with: " ")
            rows.append((k.id, name + "\n" + e.searchText))
        }
        if !rows.isEmpty { writer.setNameRows(rows) }
    }

    /// Copy a citation for an entry (or the PDF at `path`). Reference entries (e.g. from a conference archive's .bib)
    /// are first added to library.bib with a new key.
    func cite(entry: BibEntry?, path: String?, style: CiteStyle) {
        guard var e = entry ?? path.flatMap({ bib.entry(forPath: $0) }) else {
            noDetailsAlert()
            return
        }
        var added = false
        if !e.inLibrary {
            guard let r = ensureInLibrary(e) else { return }
            e = r.entry
            added = r.added
        }
        let text: String
        switch style {
        case .pandoc: text = "[@\(e.key)]"
        case .latex: text = "\\cite{\(e.key)}"
        case .key: text = e.key
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showFlash("Copied \(text)" + (added ? " · added to library.bib" : ""))
    }

    /// A reference entry (e.g. from a conference archive) becomes a library entry with a regular key.
    /// Returns nil if library.bib couldn't be written (an alert explains why).
    func ensureInLibrary(_ e: BibEntry) -> (entry: BibEntry, added: Bool)? {
        if e.inLibrary { return (e, false) }
        // already in the library under another key (same DOI or same PDF)?
        let doi = e.fields["doi"]?.lowercased()
        if let existing = bib.entries.first(where: { x in
            x.inLibrary && ((doi != nil && x.fields["doi"]?.lowercased() == doi) || (x.file != nil && x.file == e.file))
        }) {
            return (existing, false)
        }
        let key = CiteKey.make(for: e, existing: bib.libraryKeys)
        var fields = e.raw
        fields["file"] = nil
        let text = BibWriter.format(type: e.type, key: key, fields: fields, file: e.file)
        do {
            try BibWriter.append(text, to: URL(fileURLWithPath: Paths.libraryBib))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't add the entry to library.bib"
            alert.informativeText = "\(Paths.libraryBib)\n\n\(error.localizedDescription)"
            alert.runModal()
            return nil
        }
        let newEntry = BibEntry(type: e.type, key: key, fields: e.fields, raw: fields, inLibrary: true, file: e.file)
        bib = BibIndex(entries: bib.entries + [newEntry])
        reloadBib(force: true)
        return (newEntry, true)
    }

    // MARK: margin notes → search index + Obsidian

    /// Called after the open PDF was saved with new/changed highlights or notes.
    func afterSave(path: String, notes: [MarginNote], summary: String) {
        writeQ.async { self.index([URL(fileURLWithPath: path)]) }   // so new notes are searchable
        var entry = bib.entry(forPath: path)
        if let e = entry, !e.inLibrary, !notes.isEmpty || !summary.isEmpty { entry = ensureInLibrary(e)?.entry ?? e }
        Marginalia.mirror(pdfPath: path, entry: entry, notes: notes, summary: summary)
    }

    /// File ▸ Write Notes for All Annotated PDFs: a note for every PDF that has highlights or notes.
    func exportAllMarginalia() {
        showFlash("Writing paper notes…")
        writeQ.async {
            let paths = Array(self.writer.knownFiles().keys).sorted()
            DispatchQueue.global(qos: .utility).async {
                var written = 0
                for (i, p) in paths.enumerated() {
                    autoreleasepool {
                        guard let doc = PDFDocument(url: URL(fileURLWithPath: p)), !doc.isLocked else { return }
                        let notes = Marginalia.collect(doc)
                        let summary = Marginalia.summary(doc)
                        guard !notes.isEmpty || !summary.isEmpty else { return }
                        DispatchQueue.main.sync {
                            var entry = self.bib.entry(forPath: p)
                            if let e = entry, !e.inLibrary { entry = self.ensureInLibrary(e)?.entry ?? e }
                            Marginalia.mirror(pdfPath: p, entry: entry, notes: notes, summary: summary)
                        }
                        written += 1
                    }
                    if i % 100 == 0 {
                        let n = i
                        DispatchQueue.main.async { self.showFlash("Writing paper notes… \(n) of \(paths.count) PDFs checked") }
                    }
                }
                let total = written
                DispatchQueue.main.async {
                    self.showFlash(Paths.writeNotes ? "Wrote \(total) paper notes to \(Marginalia.folder.replacingOccurrences(of: NSHomeDirectory(), with: "~"))" : "Paper notes are turned off in Settings")
                }
            }
        }
    }

    /// PDFs/folders opened with the app, and pdfsearch://open?file=…&page=… links from Obsidian notes.
    func handle(_ urls: [URL]) {
        var files: [URL] = []
        for u in urls {
            if u.scheme == "pdfsearch" {
                let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard let file = items.first(where: { $0.name == "file" })?.value else { continue }
                let page = Int(items.first(where: { $0.name == "page" })?.value ?? "") ?? 0
                let path = (file as NSString).expandingTildeInPath
                // SwiftUI and the app delegate can both deliver the same link
                if let last = linkRequest, last.path == path, last.page == page,
                   Date().timeIntervalSince(lastLinkTime) < 1 { continue }
                lastLinkTime = Date()
                linkRequest = LinkRequest(path: path, page: page, n: (linkRequest?.n ?? 0) + 1)
                NSApp.activate(ignoringOtherApps: true)
            } else if u.isFileURL {
                files.append(u)
            }
        }
        if !files.isEmpty { add(files) }
    }

    func showFlash(_ message: String) {
        flashGen += 1
        let g = flashGen
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if g == self.flashGen { self.flash = nil } }
    }

    private static func onUnpluggedVolume(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/") else { return false }
        let parts = path.split(separator: "/")
        return parts.count >= 2 && !FileManager.default.fileExists(atPath: "/Volumes/" + parts[1])
    }

    // MARK: adding & updating

    /// Add Folder to Search…: index a folder without adding anything to the bibliography.
    func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Search This Folder"
        panel.message = "Choose a folder of PDFs to make searchable"
        if panel.runModal() == .OK { add(panel.urls) }
    }

    /// Add Paper (PDF)…: pick PDFs, then confirm each one's citation details.
    func choosePapers() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.pdf]
        panel.prompt = "Add"
        panel.message = "Choose PDFs to add to your library"
        if panel.runModal() == .OK { requestAdd(panel.urls) }
    }

    /// Show the Add card for each file in turn (nil = book/chapter without a PDF).
    func requestAdd(_ files: [URL?]) {
        addQueue += files
        if addRequest == nil { nextAdd() }
    }

    func nextAdd() {
        guard addRequest == nil, !addQueue.isEmpty else { return }
        let f = addQueue.removeFirst()
        DispatchQueue.main.async { self.addRequest = AddRequest(file: f) }
    }

    /// Dropped onto the window: folders become searchable; PDFs already in the bibliography are just
    /// indexed; new PDFs get the Add card (or, for many at once, the choice of just searching them).
    func handleDropped(_ urls: [URL]) {
        var folders: [URL] = [], known: [URL] = [], new: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue { folders.append(u) }
            else if u.pathExtension.lowercased() == "pdf" {
                if bib.entry(forPath: u.standardizedFileURL.path) != nil { known.append(u) } else { new.append(u) }
            }
        }
        if !folders.isEmpty || !known.isEmpty { add(folders + known) }
        guard !new.isEmpty else { return }
        if new.count > 3 {
            let alert = NSAlert()
            alert.messageText = "Add \(new.count) PDFs to your library?"
            alert.informativeText = "Adding looks up each paper's citation details and moves it into Papers/Library, one card at a time. Or just make them searchable where they are."
            alert.addButton(withTitle: "Add to Library")
            alert.addButton(withTitle: "Just Search Them")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: requestAdd(new)
            case .alertSecondButtonReturn: add(new)
            default: break
            }
        } else {
            requestAdd(new)
        }
    }

    /// Save a confirmed entry: move/copy the PDF to Library/<key>.pdf and append to library.bib.
    @discardableResult
    func addToLibrary(type: String, key: String, fields: [String: String], file: URL?, move: Bool) -> Bool {
        let fm = FileManager.default
        var dest: String?
        if let src = file?.standardizedFileURL {
            let dir = Paths.libraryFolder
            var d = dir + "/" + key + ".pdf"
            if fm.fileExists(atPath: d) && d != src.path { d = dir + "/" + key + "-2.pdf" }
            do {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                if src.path != d {
                    if move { try fm.moveItem(atPath: src.path, toPath: d) } else { try fm.copyItem(atPath: src.path, toPath: d) }
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't put the PDF in your Library folder"
                alert.informativeText = error.localizedDescription
                alert.runModal()
                return false
            }
            dest = d
        }
        let text = BibWriter.format(type: type, key: key, fields: fields, file: dest)
        do {
            try BibWriter.append(text, to: URL(fileURLWithPath: Paths.libraryBib))
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't add the entry to library.bib"
            alert.informativeText = "\(Paths.libraryBib)\n\n\(error.localizedDescription)"
            alert.runModal()
            return false
        }
        if let e = BibParser.parse(text, inLibrary: true).first { bib = BibIndex(entries: bib.entries + [e]) }
        reloadBib(force: true)
        refresh()   // index the new file and forget its old location
        showFlash("Added @\(key) to your library")
        if let d = dest {
            linkRequest = LinkRequest(path: d, page: 0, n: (linkRequest?.n ?? 0) + 1)
        } else {
            query = key
        }
        return true
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
            // ~/Papers is always part of the library
            if fm.fileExists(atPath: Paths.papers) { self.writer.addFolder(Paths.papers) }
            // forget added folders that no longer exist (moved or deleted), unless they're on an unplugged drive
            for f in self.writer.folders() where !fm.fileExists(atPath: f) && !Library.onUnpluggedVolume(f) {
                self.writer.removeFolder(f)
            }
            var urls: [URL] = []
            for (path, k) in self.writer.knownFiles() {
                if fm.fileExists(atPath: path) {
                    urls.append(URL(fileURLWithPath: path))
                } else if !Library.onUnpluggedVolume(path) {
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
            DispatchQueue.main.async { self.progress = nil; self.reloadBib(); self.runSearchNow() }
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
        applyBibToIndex(bibForIndex)
        publishCount()
        DispatchQueue.main.async { self.progress = nil; self.reloadBib(); self.runSearchNow() }
    }

    private func publishCount() {
        let n = writer.count(scope: nil)
        let f = writer.folderList()
        let paths = Set(writer.knownFiles().keys.map(BibIndex.norm))
        DispatchQueue.main.async {
            self.docCount = n
            self.folders = f
            self.indexedPaths = paths
            if let s = self.scope, !f.contains(where: { $0.path == s }),
               !self.collections.contains(where: { $0.path == s }) { self.scope = nil }
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
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { pages.append(""); continue }
            var text = page.string ?? ""
            // your margin notes are part of the page, so searching finds them
            let notes = page.annotations.filter(Marginalia.isMarkup).compactMap { $0.contents }.filter { !$0.isEmpty }
            if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
            pages.append(text)
        }
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
        let coll = collections.first { $0.path == self.scope }
        let scope = coll == nil ? self.scope : nil       // a collection searches everything, then filters
        let bib = self.bib
        let indexed = self.indexedPaths
        readQ.async {
            let (fts, terms) = Library.parse(q)
            let empty = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            var hits: [Hit]
            if empty {
                hits = self.reader.allFiles(scope: scope)
            } else if fts.isEmpty {
                hits = []
            } else {
                hits = self.reader.search(fts, scope: scope)
            }
            for i in hits.indices { hits[i].entry = bib.entry(forPath: hits[i].path) }
            let keySet = coll?.keySet ?? []
            if coll != nil {
                hits = hits.filter { h in h.entry.map { $0.inLibrary && keySet.contains($0.key) } ?? false }
            }
            // library entries without an indexed PDF (books etc.) belong to the Library folder
            let lib = Paths.libraryFolder
            if coll != nil || scope == nil || scope == lib || lib.hasPrefix(scope! + "/") {
                let folded = terms.map(BibIndex.fold).filter { !$0.isEmpty }
                for (i, e) in bib.entries.enumerated() where e.inLibrary && (coll == nil || keySet.contains(e.key)) {
                    if let f = e.file, indexed.contains(BibIndex.norm(f)) { continue }
                    if indexed.contains(BibIndex.norm(lib + "/" + e.key + ".pdf")) { continue }
                    if !empty && !Library.entryMatches(bib.searchBlobs[i], folded) { continue }
                    hits.append(Hit(id: -(i + 1), path: "", page: 0, badge: e.kindLabel + " · no PDF", snippet: nil, entry: e))
                }
            }
            if empty, let c = coll {
                // a collection lists its items in the order of the note
                let order = Dictionary(c.keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
                hits.sort { (order[$0.entry?.key ?? ""] ?? Int.max) < (order[$1.entry?.key ?? ""] ?? Int.max) }
            } else if empty {
                hits.sort { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
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

    /// Every term must match: a phrase anywhere, a word at the start of a word.
    static func entryMatches(_ blob: String, _ terms: [String]) -> Bool {
        for t in terms {
            if t.contains(" ") {
                if !blob.contains(t) { return false }
            } else if !(blob.hasPrefix(t) || blob.contains(" " + t)) {
                return false
            }
        }
        return true
    }

    private static func hasWordChars(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - Bibliography (library.bib + reference .bib files)

/// One BibTeX entry. `fields` holds display-ready text (LaTeX decoded); `raw` holds values as written.
struct BibEntry: Identifiable {
    let type: String
    let key: String
    let fields: [String: String]
    let raw: [String: String]
    let inLibrary: Bool          // true = from library.bib (citable as is); false = a reference collection (e.g. a conference archive)
    let file: String?            // absolute path to the PDF, if any
    var id: String { (inLibrary ? "L:" : "R:") + key }

    var title: String { fields["title"] ?? "" }
    var year: String {
        let y = fields["year"] ?? fields["date"] ?? ""
        if let r = y.range(of: "[0-9]{4}", options: .regularExpression) { return String(y[r]) }
        return ""
    }
    /// Authors, or editors when there are no authors.
    var people: [String] {
        let s = fields["author"] ?? fields["editor"] ?? ""
        return s.components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    static func lastName(_ person: String) -> String {
        if let comma = person.firstIndex(of: ",") { return String(person[..<comma]).trimmingCharacters(in: .whitespaces) }
        return person.split(separator: " ").last.map(String.init) ?? person
    }
    /// "Cascone (2000)", "Fasciani & Goode (2021)", "Smith et al. (2019)"
    var shortCite: String {
        let names = people.map(BibEntry.lastName)
        let who: String
        switch names.count {
        case 0: who = "Anon."
        case 1: who = names[0]
        case 2: who = "\(names[0]) & \(names[1])"
        default: who = "\(names[0]) et al."
        }
        return year.isEmpty ? who : "\(who) (\(year))"
    }
    var container: String {
        fields["journal"] ?? fields["journaltitle"] ?? fields["booktitle"] ?? fields["publisher"] ?? ""
    }
    /// Text that makes the entry findable by author, title, year and key.
    var searchText: String {
        ([key, title, fields["author"] ?? "", fields["editor"] ?? "", year, container]).joined(separator: "\n")
    }
    var kindLabel: String {
        switch type {
        case "book": return "Book"
        case "incollection", "inbook": return "Chapter"
        case "article": return "Article"
        case "inproceedings", "conference": return "Paper"
        case "phdthesis", "mastersthesis", "thesis": return "Thesis"
        default: return type.capitalized
        }
    }
}

/// Everything loaded from the .bib files, looked up by PDF path or file name.
struct BibIndex {
    var entries: [BibEntry] = []
    var byPath: [String: BibEntry] = [:]          // NFC path → entry
    var libraryByStem: [String: BibEntry] = [:]   // "cascone2000aesthetics" → entry (PDFs named by key)
    var libraryKeys: Set<String> = []
    var searchBlobs: [String] = []                 // folded search text, parallel to `entries`

    static func norm(_ path: String) -> String { path.precomposedStringWithCanonicalMapping }

    /// lowercase ASCII words separated by single spaces (for matching typed words against entries)
    static func fold(_ s: String) -> String {
        CiteKey.ascii(s).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    func entry(forPath path: String) -> BibEntry? {
        if let e = byPath[BibIndex.norm(path)] { return e }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return libraryByStem[stem]
    }

    init() {}
    init(entries: [BibEntry]) {
        self.entries = entries
        searchBlobs = entries.map { BibIndex.fold($0.searchText) }
        for e in entries {
            if let f = e.file {
                let k = BibIndex.norm(f)
                // library entries win over reference ones for the same PDF
                if byPath[k] == nil || e.inLibrary { byPath[k] = e }
            }
            if e.inLibrary {
                libraryKeys.insert(e.key)
                libraryByStem[e.key] = e
            }
        }
    }
}

enum BibParser {
    static func parse(_ text: String, inLibrary: Bool) -> [BibEntry] {
        let b = Array(text.utf8)
        let n = b.count
        var i = 0
        var out: [BibEntry] = []
        func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        func skipSpace() { while i < n && isSpace(b[i]) { i += 1 } }
        func str(_ from: Int, _ to: Int) -> String { String(decoding: b[from..<to], as: UTF8.self) }
        /// i points at an opening brace; returns the content and leaves i after the matching brace
        func braced() -> String {
            var depth = 0
            let start = i + 1
            while i < n {
                if b[i] == UInt8(ascii: "{") { depth += 1 }
                else if b[i] == UInt8(ascii: "}") { depth -= 1; if depth == 0 { i += 1; return str(start, i - 1) } }
                else if b[i] == UInt8(ascii: "\\") { i += 1 }
                i += 1
            }
            return str(start, n)
        }
        func quoted() -> String {
            let start = i + 1
            i += 1
            var depth = 0
            while i < n {
                let c = b[i]
                if c == UInt8(ascii: "{") { depth += 1 }
                else if c == UInt8(ascii: "}") { depth -= 1 }
                else if c == UInt8(ascii: "\\") { i += 1 }
                else if c == UInt8(ascii: "\"") && depth <= 0 { i += 1; return str(start, i - 1) }
                i += 1
            }
            return str(start, n)
        }

        while i < n {
            while i < n && b[i] != UInt8(ascii: "@") { i += 1 }
            guard i < n else { break }
            i += 1
            let ts = i
            while i < n && (isalpha(Int32(b[i])) != 0) { i += 1 }
            let type = str(ts, i).lowercased()
            skipSpace()
            guard i < n, b[i] == UInt8(ascii: "{") || b[i] == UInt8(ascii: "(") else { continue }
            if type == "comment" || type == "preamble" || type == "string" {
                if b[i] == UInt8(ascii: "{") { _ = braced() }
                continue
            }
            i += 1
            skipSpace()
            let ks = i
            while i < n && b[i] != UInt8(ascii: ",") && b[i] != UInt8(ascii: "}") && !isSpace(b[i]) { i += 1 }
            let key = str(ks, i)
            var raw: [String: String] = [:]
            // fields
            while i < n {
                while i < n && (isSpace(b[i]) || b[i] == UInt8(ascii: ",")) { i += 1 }
                guard i < n else { break }
                if b[i] == UInt8(ascii: "}") || b[i] == UInt8(ascii: ")") { i += 1; break }
                let ns = i
                while i < n && b[i] != UInt8(ascii: "=") && b[i] != UInt8(ascii: ",") && b[i] != UInt8(ascii: "}") && !isSpace(b[i]) { i += 1 }
                let name = str(ns, i).lowercased()
                skipSpace()
                guard i < n, b[i] == UInt8(ascii: "=") else { continue }
                i += 1
                var value = ""
                while true {
                    skipSpace()
                    guard i < n else { break }
                    if b[i] == UInt8(ascii: "{") { value += braced() }
                    else if b[i] == UInt8(ascii: "\"") { value += quoted() }
                    else {
                        let vs = i
                        while i < n && b[i] != UInt8(ascii: ",") && b[i] != UInt8(ascii: "}") && b[i] != UInt8(ascii: "#") && !isSpace(b[i]) { i += 1 }
                        value += str(vs, i)
                    }
                    skipSpace()
                    if i < n && b[i] == UInt8(ascii: "#") { i += 1; continue }
                    break
                }
                if !name.isEmpty { raw[name] = value }
            }
            guard !key.isEmpty else { continue }
            var fields: [String: String] = [:]
            for (k, v) in raw { fields[k] = (k == "url" || k == "doi" || k == "file") ? v.trimmingCharacters(in: .whitespacesAndNewlines) : decodeLaTeX(v) }
            out.append(BibEntry(type: type, key: key, fields: fields, raw: raw, inLibrary: inLibrary,
                                file: filePath(fields["file"])))
        }
        return out
    }

    /// Accepts "/path/x.pdf", "~/x.pdf", or JabRef/Zotero style ":/path/x.pdf:PDF;…".
    static func filePath(_ value: String?) -> String? {
        guard let v = value, !v.isEmpty else { return nil }
        for part in v.components(separatedBy: ";") {
            var p = part.trimmingCharacters(in: .whitespaces)
            if let r = p.range(of: ".pdf", options: [.caseInsensitive, .backwards]) { p = String(p[..<r.upperBound]) }
            if let s = p.firstIndex(where: { $0 == "/" || $0 == "~" }) { p = String(p[s...]) }
            guard p.lowercased().hasSuffix(".pdf") else { continue }
            p = (p as NSString).expandingTildeInPath
            return URL(fileURLWithPath: p).standardizedFileURL.path
        }
        return nil
    }

    private static let accentMarks: [Character: String] = [
        "'": "\u{301}", "`": "\u{300}", "^": "\u{302}", "\"": "\u{308}", "~": "\u{303}", "=": "\u{304}",
        ".": "\u{307}", "u": "\u{306}", "v": "\u{30C}", "H": "\u{30B}", "c": "\u{327}", "k": "\u{328}", "r": "\u{30A}"]
    private static let specials: [String: String] = [
        "ss": "ß", "o": "ø", "O": "Ø", "aa": "å", "AA": "Å", "ae": "æ", "AE": "Æ", "oe": "œ", "OE": "Œ",
        "l": "ł", "L": "Ł", "i": "ı", "j": "ȷ"]

    /// Light LaTeX → text: accents, escaped symbols, dashes, braces.
    static func decodeLaTeX(_ s: String) -> String {
        guard s.contains("\\") || s.contains("{") || s.contains("--") || s.contains("~") else {
            return s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let c = Array(s)
        var out = ""
        var i = 0
        /// the letter an accent applies to, starting at index j: "e", "{e}", " e", "{\\i}"; returns (letter, next index)
        func accentTarget(_ start: Int) -> (Character, Int)? {
            var j = start
            while j < c.count && c[j] == " " { j += 1 }
            guard j < c.count else { return nil }
            if c[j] == "{" {
                var k = j + 1
                if k < c.count && c[k] == "\\" { k += 1 }
                guard k < c.count, c[k].isLetter else { return nil }
                let letter = c[k]
                var e = k + 1
                while e < c.count && c[e] != "}" { e += 1 }
                return (letter, min(e + 1, c.count))
            }
            return c[j].isLetter ? (c[j], j + 1) : nil
        }
        while i < c.count {
            let ch = c[i]
            if ch == "\\" && i + 1 < c.count {
                let nx = c[i + 1]
                let symbolAccent = "'`^\"~=.".contains(nx)
                let letterAccent = "uvHckr".contains(nx) && i + 2 < c.count && (c[i + 2] == "{" || c[i + 2] == " ")
                if symbolAccent || letterAccent, let mark = accentMarks[nx], let target = accentTarget(i + 2) {
                    out += String(target.0) + mark
                    i = target.1
                    continue
                }
                var k = i + 1
                while k < c.count && c[k].isLetter { k += 1 }
                let word = String(c[(i + 1)..<k])
                if let sp = specials[word] {
                    out += sp
                    i = k
                    if i < c.count && c[i] == " " { i += 1 }   // "\\ss " eats one space
                    continue
                }
                if !word.isEmpty { i = k; continue }   // unknown command (\\textit…): drop it, keep the argument
                out.append(nx)                          // \\& \\% \\_ \\# \\$ \\{ \\}
                i += 2
                continue
            }
            if ch == "{" || ch == "}" { i += 1; continue }
            out.append(ch == "~" ? " " : ch)
            i += 1
        }
        out = out.replacingOccurrences(of: "---", with: "—").replacingOccurrences(of: "--", with: "–")
        return out.precomposedStringWithCanonicalMapping
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

/// Citation keys: last name + year + first meaningful title word, all lowercase ASCII.
/// e.g. Cascone (2000) "The Aesthetics of Failure" → cascone2000aesthetics.
/// The same rule is used by the one-time Zotero import script; keep them in sync.
enum CiteKey {
    static let stopwords: Set<String> = [
        "a", "an", "the", "on", "of", "in", "for", "and", "to", "toward", "towards", "with", "from", "at", "by",
        "into", "about", "via", "is", "are", "as", "what", "how", "why", "when", "do", "does", "can", "some",
        "its", "it", "this", "that", "these", "those", "or", "vs", "versus", "le", "la", "les", "el", "los",
        "las", "der", "die", "das", "den", "ein", "eine", "und", "von", "zu", "im", "di", "da", "de", "du", "des"]

    static func ascii(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "æ", with: "ae")
            .replacingOccurrences(of: "Æ", with: "ae").replacingOccurrences(of: "œ", with: "oe")
            .replacingOccurrences(of: "ø", with: "o").replacingOccurrences(of: "Ø", with: "o")
            .replacingOccurrences(of: "ł", with: "l").replacingOccurrences(of: "Ł", with: "l")
            .replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "þ", with: "th")
        t = t.applyingTransform(.stripDiacritics, reverse: false) ?? t
        return t.lowercased()
    }

    static func make(lastName: String, year: String, title: String, existing: Set<String>) -> String {
        let name = String(ascii(lastName).unicodeScalars.filter { ("a"..."z").contains($0) || ("0"..."9").contains($0) }.map { Character($0) })
        let y = year.range(of: "[0-9]{4}", options: .regularExpression).map { String(year[$0]) } ?? "nd"
        let words = ascii(title).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let word = words.first { !stopwords.contains($0) } ?? ""
        let base = (name.isEmpty ? "anon" : name) + y + word
        if !existing.contains(base) { return base }
        for suffix in "bcdefghijklmnopqrstuvwxyz" where !existing.contains(base + String(suffix)) {
            return base + String(suffix)
        }
        return base + String(Int.random(in: 100...999))
    }

    static func make(for e: BibEntry, existing: Set<String>) -> String {
        make(lastName: e.people.first.map(BibEntry.lastName) ?? "", year: e.year, title: e.title, existing: existing)
    }
}

enum BibWriter {
    static let order = ["author", "editor", "title", "booktitle", "journal", "journaltitle", "chapter", "edition",
                        "volume", "number", "series", "pages", "publisher", "school", "institution", "address",
                        "year", "month", "date", "doi", "isbn", "issn", "url", "urldate", "note"]

    /// Escape characters LaTeX would choke on (not for url/doi/file).
    static func escape(_ v: String) -> String {
        var s = ""
        var prev: Character = " "
        for ch in v {
            if "&%#_".contains(ch) && prev != "\\" { s.append("\\") }
            s.append(ch)
            prev = ch
        }
        return s.replacingOccurrences(of: "–", with: "--").replacingOccurrences(of: "—", with: "---")
    }

    static func format(type: String, key: String, fields: [String: String], file: String?) -> String {
        var lines: [String] = []
        let verbatim: Set<String> = ["url", "doi", "file"]
        var keys = order.filter { fields[$0] != nil }
        keys += fields.keys.filter { !order.contains($0) && $0 != "file" }.sorted()
        for k in keys {
            guard let v = fields[k], !v.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append("  \(k) = {\(verbatim.contains(k) ? v : escape(v))}")
        }
        if let f = file { lines.append("  file = {\(f)}") }
        return "@\(type){\(key),\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    /// Appends an entry to the end of library.bib (creating it if needed).
    static func append(_ text: String, to url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try ("% library.bib: written by PDF Search. One entry per item; keys never change.\n\n" + text)
                .write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: ("\n" + text).data(using: .utf8)!)
    }
}

/// `PDFSearch --selftest` (run by build.sh): exercises the bibliography code and prints results to the build log.
enum SelfTest {
    static func run() {
        let sample = """
        @article{x, author = {M{\\"u}ller, J{\\'e}r{\\^o}me and O'Brien, Pat}, title = {The {Aesthetics} of Failure: Post-Digital Tendencies},
          journal = {Computer Music Journal}, year = 2000, pages = {12--18}}
        @comment{ignore me}
        @book{y, editor = "Collins, Nicolas", title = "Handmade Electronic Music \\& More", year = {2006},
          publisher = {Routledge}, file = {:/Users/x/Papers/Library/y.pdf:PDF}}
        @incollection{z, author = {Fasciani, Stefano and Goode, Jackson and Third, A.}, title = {20 {Years} of Interfaces}, booktitle = {Proc. ICMC}, year = {2021}}
        @misc{w, author = {\\v{S}iška, Martin and Ø{\\ss}e, K}, title = {On the {\\textit{Glitch}}}, date = {2019-04-01}}
        """
        let es = BibParser.parse(sample, inLibrary: true)
        print("SELFTEST parsed \(es.count) entries (expect 4)")
        var keys = Set<String>()
        for e in es {
            let k = CiteKey.make(for: e, existing: keys)
            keys.insert(k)
            print("SELFTEST \(e.type) \(e.key) | title=\(e.title) | people=\(e.people) | cite=\(e.shortCite) | newkey=\(k) | file=\(e.file ?? "-")")
        }
        print("SELFTEST clash: " + CiteKey.make(lastName: "Cascone", year: "2000", title: "The Aesthetics of Failure", existing: ["cascone2000aesthetics"]))
        print("SELFTEST fold: " + BibIndex.fold("Müller, Jérôme (2000) The Aesthetics"))
        print("SELFTEST write:\n" + BibWriter.format(type: "book", key: "k", fields: ["title": "A & B – C", "author": "Smith, J", "url": "http://x.org/a_b"], file: "/p/k.pdf"))
        let round = BibParser.parse(BibWriter.format(type: "book", key: "k", fields: ["title": "A & B – C"], file: "/p/k.pdf"), inLibrary: true)
        print("SELFTEST roundtrip: \(round.first?.title ?? "FAIL") file=\(round.first?.file ?? "-")")
        print("SELFTEST collection keys: \(Collection.keys(in: "- [[@cascone2000aesthetics]] x\n- [@menkman2011glitch, p. 3] mail me@x.com\n@collins2006handmade. and @cascone2000aesthetics again"))")
        print("SELFTEST ids: doi=\(Lookup.doi(in: "https://doi.org/10.1162/014892600559489.") ?? "-") arxiv=\(Lookup.arxiv(in: "arXiv:2103.01234v2 [cs.SD]") ?? "-") isbn=\(Lookup.isbn(in: "ISBN 978-0-415-99873-4") ?? "-") isbnText=\(Lookup.isbnInText("Printed in UK. ISBN-13: 978-0-415-99873-4 (pbk)") ?? "-") notIsbn=\(Lookup.isbn(in: "The Aesthetics of Failure") ?? "-") name=\(Lookup.lastFirst("Kim Cascone")) kind=\(Lookup.kind("journal-article").rawValue)")
        let link = Marginalia.link(path: "/Users/x/Papers/Proceedings 2021/smith & jones (draft) #2.pdf", page: 3)
        let back = URLComponents(string: link)?.queryItems?.first(where: { $0.name == "file" })?.value ?? "FAIL"
        print("SELFTEST link: \(link)\nSELFTEST link decodes to: \(back)")
        for p in [Paths.libraryBib] {
            guard let t = try? String(contentsOfFile: p, encoding: .utf8) else { print("SELFTEST (no file) \(p)"); continue }
            let fs = BibParser.parse(t, inLibrary: true)
            let withFile = fs.filter { $0.file != nil }
            let present = withFile.filter { FileManager.default.fileExists(atPath: $0.file!) }
            print("SELFTEST file \(p): \(fs.count) entries, \(withFile.count) with a PDF path, \(present.count) of those exist; first: \(fs.first.map { $0.shortCite + " " + $0.title } ?? "-")")
        }
    }
}

// MARK: - Marginalia: highlights + notes in the PDF, mirrored into Obsidian

struct MarginNote: Identifiable {
    let annotation: PDFAnnotation
    let pageIndex: Int
    let pageLabel: String       // the printed page number when the PDF has one
    let quote: String
    let comment: String
    let color: NSColor
    var id: ObjectIdentifier { ObjectIdentifier(annotation) }
}

enum Marginalia {
    static let markupTypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly", "Text", "FreeText"]
    static func isMarkup(_ a: PDFAnnotation) -> Bool {
        markupTypes.contains((a.type ?? "").replacingOccurrences(of: "/", with: ""))
    }
    /// folder for paper notes (Obsidian vault/Literature, or ~/Papers/Notes without Obsidian)
    static var folder: String { Paths.notesFolder }
    static let summaryHeading = "Summary"
    static func isSummary(_ a: PDFAnnotation) -> Bool {
        let t = (a.type ?? "").replacingOccurrences(of: "/", with: "")
        let c = a.contents ?? ""
        return t == "Text" && (c == summaryHeading || c.hasPrefix(summaryHeading + "\n") || c.hasPrefix(summaryHeading + "\r"))
    }
    static func summaryAnnotation(_ doc: PDFDocument) -> PDFAnnotation? {
        doc.page(at: 0)?.annotations.first(where: isSummary)
    }
    /// the "About this paper" text (without its "Summary" first line)
    static func summary(_ doc: PDFDocument) -> String {
        guard let c = summaryAnnotation(doc)?.contents else { return "" }
        return String(c.dropFirst(summaryHeading.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let startMarker = "<!-- marginalia:start -->"
    static let endMarker = "<!-- marginalia:end -->"

    /// All highlights and notes in a PDF, in reading order.
    static func collect(_ doc: PDFDocument) -> [MarginNote] {
        var out: [MarginNote] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let label = page.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(i + 1)
            let anns = page.annotations.filter { isMarkup($0) && !isSummary($0) }.sorted { a, b in
                if abs(a.bounds.maxY - b.bounds.maxY) > 3 { return a.bounds.maxY > b.bounds.maxY }
                return a.bounds.minX < b.bounds.minX
            }
            for a in anns {
                out.append(MarginNote(annotation: a, pageIndex: i, pageLabel: label, quote: quote(a, page),
                                      comment: (a.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                      color: a.color))
            }
        }
        return out
    }

    /// The text under a highlight, line by line.
    static func quote(_ a: PDFAnnotation, _ page: PDFPage) -> String {
        let t = (a.type ?? "").replacingOccurrences(of: "/", with: "")
        if t == "Text" || t == "FreeText" { return "" }
        var rects: [CGRect] = []
        if let q = a.quadrilateralPoints, q.count >= 4 {
            for k in stride(from: 0, to: q.count - 3, by: 4) {
                let pts = q[k..<(k + 4)].map { $0.pointValue }
                let xs = pts.map { $0.x }, ys = pts.map { $0.y }
                if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
                    rects.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
                }
            }
        }
        func text(_ rs: [CGRect]) -> String {
            rs.compactMap { r in page.selection(for: r.insetBy(dx: 0, dy: r.height * 0.25))?.string }.joined(separator: " ")
        }
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var s = ""
        if !rects.isEmpty {
            s = text(rects.map { $0.offsetBy(dx: a.bounds.minX, dy: a.bounds.minY) })   // PDFKit: relative to the annotation
            if blank(s) { s = text(rects) }                                               // some files: page coordinates
        }
        if blank(s) { s = page.selection(for: a.bounds)?.string ?? "" }
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // re-join words hyphenated across lines ("compo- sition")
        if let re = try? NSRegularExpression(pattern: "([a-z])- ([a-z])") {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "$1$2")
        }
        return s
    }

    /// pdfsearch://open?file=…&page=… (opens PDF Search at that page)
    static func link(path: String, page: Int) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        let f = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return "pdfsearch://open?file=\(f)&page=\(page)"
    }

    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func header(pdfPath: String, entry: BibEntry?, key: String) -> String {
        let stem = ((pdfPath as NSString).lastPathComponent as NSString).deletingPathExtension
        var h = "---\n"
        if let e = entry {
            h += "citekey: \(e.key)\n"
            h += "title: \(yaml(e.title))\n"
            if !e.people.isEmpty { h += "authors: \(yaml(e.people.joined(separator: "; ")))\n" }
            if !e.year.isEmpty { h += "year: \(e.year)\n" }
        }
        h += "pdf: \(yaml(pdfPath))\n---\n\n"
        let title = (entry?.title).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        h += "# \(title)\n\n"
        var bits: [String] = []
        if let e = entry { bits.append(e.shortCite); bits.append("`[@\(e.key)]`") }
        bits.append("[Open in PDF Search](\(link(path: pdfPath, page: 1)))")
        return h + bits.joined(separator: " · ") + "\n\n"
    }

    static func block(pdfPath: String, entry: BibEntry?, notes: [MarginNote], summary: String) -> String {
        var b = startMarker + "\n"
        b += "*This section is updated automatically from the PDF (its summary and highlights). Write them in PDF Search; write your own notes below this section — they're never touched.*\n\n"
        if !summary.isEmpty { b += "## Summary\n\n" + summary + "\n\n" }
        b += "## Marginalia\n\n"
        if notes.isEmpty { b += "*(no highlights yet)*\n\n" }
        for n in notes {
            let pageLink = "[p. \(n.pageLabel)](\(link(path: pdfPath, page: n.pageIndex + 1)))"
            let cite = entry.map { " [@\($0.key), p. \(n.pageLabel)]" } ?? ""
            if !n.quote.isEmpty {
                b += "> “\(n.quote)” (\(pageLink))\(cite)\n\n"
            } else {
                b += "**\(pageLink)**\(cite)\n\n"
            }
            if !n.comment.isEmpty { b += n.comment + "\n\n" }
        }
        return b + endMarker
    }

    /// Create or update <notes folder>/@key.md. Only the marginalia block is rewritten.
    static func mirror(pdfPath: String, entry: BibEntry?, notes: [MarginNote], summary: String) {
        let stem = ((pdfPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let key = entry?.key ?? stem
        let name = "@" + key.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md"
        let fm = FileManager.default
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        let exists = fm.fileExists(atPath: url.path)
        guard Paths.writeNotes, exists || !notes.isEmpty || !summary.isEmpty else { return }
        do {
            try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let newBlock = block(pdfPath: pdfPath, entry: entry, notes: notes, summary: summary)
            var text = exists ? ((try? String(contentsOf: url, encoding: .utf8)) ?? "") : ""
            if text.isEmpty {
                text = header(pdfPath: pdfPath, entry: entry, key: key) + newBlock + "\n\n## Notes\n\n"
            } else if let s = text.range(of: startMarker),
                      let e = text.range(of: endMarker, range: s.upperBound..<text.endIndex) {
                text.replaceSubrange(s.lowerBound..<e.upperBound, with: newBlock)
            } else {
                text += "\n\n" + newBlock + "\n"
            }
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Library.shared.showFlash("Couldn't write the paper note: \(error.localizedDescription)")
        }
    }
}

/// The notes column beside the PDF: every highlight with its note, in page order.
struct MarginColumn: View {
    @ObservedObject var viewer: Viewer
    var body: some View {
        VStack(spacing: 0) {
            // header: title + highlight colour
            HStack(spacing: 6) {
                Text("Highlights & Notes").font(.headline)
                Spacer()
                ForEach(HighlightColor.allCases) { c in
                    Circle()
                        .fill(Color(nsColor: c.nsColor.withAlphaComponent(1)))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.primary.opacity(viewer.highlightColor == c ? 0.8 : 0), lineWidth: 2).padding(-3))
                        .onTapGesture { viewer.setHighlightColor(c) }
                        .help("Highlight in \(c.name.lowercased())")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            // the one action, shown whenever text is selected
            if viewer.hasSelection {
                Button { viewer.highlightAndComment() } label: {
                    HStack {
                        Image(systemName: "highlighter")
                        Text("Highlight selected text")
                        Spacer()
                        Text("H").font(.callout.monospaced().weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.25)))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider()
            SummaryBox(viewer: viewer)
                .id(viewer.docGen)
                .padding(10)
            Divider()

            if viewer.notes.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No highlights yet").font(.callout.weight(.medium))
                    Text("Select a passage in the PDF, then press H.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(viewer.notes) { n in
                                NoteCard(note: n, viewer: viewer).id(n.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: viewer.focusNoteID) { id in
                        if let id = id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("Select text, then press H to highlight it", systemImage: "highlighter")
                Label("Type a note under a highlight. It saves itself", systemImage: "square.and.pencil")
                Label("Click a page number to go to the passage", systemImage: "arrow.turn.down.right")
                Label("Trash button removes a highlight and its note", systemImage: "trash")
                Label("“About this paper” is for notes on the whole paper", systemImage: "doc.text")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// "About this paper": free notes on the whole paper, saved in the PDF and in its Markdown note.
struct SummaryBox: View {
    @ObservedObject var viewer: Viewer
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    private var boxHeight: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { max(1, Int(ceil(Double($0.count) / 36.0))) }
            .reduce(0, +)
        return min(220, max(64, CGFloat(lines) * 17 + 20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("About this paper", systemImage: "doc.text")
                .font(.subheadline.weight(.semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(4)
                if text.isEmpty {
                    Text("Summary, main argument, how you might use it…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: boxHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
        }
        .onAppear {
            if !loaded { text = viewer.summary; loaded = true }
        }
        .onChange(of: text) { t in if loaded { viewer.updateSummary(t) } }
    }
}

/// One highlight: page, passage, a note box that's always ready to type in, and a Remove button.
struct NoteCard: View {
    let note: MarginNote
    @ObservedObject var viewer: Viewer
    @State private var text = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    /// rough height for the note box: grows with the text, never huge
    private var boxHeight: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { max(1, Int(ceil(Double($0.count) / 34.0))) }
            .reduce(0, +)
        return min(240, max(52, CGFloat(lines) * 17 + 18))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(nsColor: note.color.withAlphaComponent(1)))
                    .frame(width: 12, height: 12)
                Button("Page \(note.pageLabel)") { viewer.reveal(note) }
                    .buttonStyle(.link)
                    .help("Go to this passage")
                Spacer()
                Button(role: .destructive) { viewer.removeHighlight(note.annotation) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this highlight and its note")
            }
            if !note.quote.isEmpty {
                Text(note.quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(5)
                    .onTapGesture { viewer.reveal(note) }
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(4)
                if text.isEmpty {
                    Text("Write a note…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: boxHeight)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(focused ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: focused ? 2 : 1))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.15)))
        .onAppear {
            if !loaded { text = note.comment; loaded = true }
            if viewer.focusNoteID == note.id { DispatchQueue.main.async { focused = true; viewer.focusNoteID = nil } }
        }
        .onChange(of: text) { t in if loaded { viewer.updateComment(note, t) } }
        .onChange(of: viewer.focusNoteID) { id in
            if id == note.id { DispatchQueue.main.async { focused = true; viewer.focusNoteID = nil } }
        }
    }
}

// MARK: - Adding papers and books (DOI / arXiv / ISBN lookup)

enum EntryKind: String, CaseIterable, Identifiable {
    case article, inproceedings, book, incollection, thesis, misc
    var id: String { rawValue }
    var label: String {
        switch self {
        case .article: return "Journal article"
        case .inproceedings: return "Conference paper"
        case .book: return "Book"
        case .incollection: return "Book chapter"
        case .thesis: return "Thesis"
        case .misc: return "Other"
        }
    }
    var bibType: String { self == .thesis ? "phdthesis" : rawValue }
    /// label for the "published in" field (nil = not shown)
    var containerLabel: String? {
        switch self {
        case .article: return "Journal"
        case .inproceedings: return "Proceedings / conference"
        case .incollection: return "Book title"
        case .thesis: return "University"
        case .misc: return "Published in"
        case .book: return nil
        }
    }
}

/// Finding identifiers in text and fetching citation details from public services.
enum Lookup {
    static let userAgent = "PDFSearch/2.1 (https://github.com/seth-thorn/pdf-search)"

    static func doi(in s: String) -> String? {
        guard let r = s.range(of: "10\\.[0-9]{4,9}/[^\\s\"<>]+", options: .regularExpression) else { return nil }
        var d = String(s[r])
        while let last = d.last, ".,;:)]}'".contains(last) { d.removeLast() }
        return d
    }
    static func arxiv(in s: String) -> String? {
        let patterns = ["arxiv\\.org/(?:abs|pdf)/([0-9]{4}\\.[0-9]{4,5})", "arXiv:\\s?([0-9]{4}\\.[0-9]{4,5})", "^\\s*([0-9]{4}\\.[0-9]{4,5})(v[0-9]+)?\\s*$"]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s) { return String(s[r]) }
        }
        return nil
    }
    /// An ISBN typed on its own ("978-0-415-99873-4", "ISBN 0415998735").
    static func isbn(in s: String) -> String? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.lowercased().hasPrefix("isbn") { t = String(t.dropFirst(4)).trimmingCharacters(in: CharacterSet(charactersIn: ":-–  ")) }
        guard t.range(of: "^[0-9Xx\\- ]+$", options: .regularExpression) != nil else { return nil }
        let digits = t.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        return (digits.count == 10 || digits.count == 13) ? digits.uppercased() : nil
    }
    /// An ISBN printed in a book's front matter.
    static func isbnInText(_ s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "ISBN(?:-1[03])?:?\\s*((?:97[89][\\- ]?)?[0-9][0-9\\- ]{7,14}[0-9Xx])"),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return isbn(in: String(s[r]))
    }

    static func kind(_ t: String) -> EntryKind {
        switch t {
        case "article-journal", "journal-article", "article-magazine", "article-newspaper": return .article
        case "paper-conference", "proceedings-article": return .inproceedings
        case "book", "monograph", "edited-book", "reference-book": return .book
        case "chapter", "book-chapter", "book-section", "book-part", "entry", "entry-encyclopedia": return .incollection
        case "thesis", "dissertation": return .thesis
        default: return .misc
        }
    }

    static func getJSON(_ url: URL, accept: String = "application/json") async throws -> Any {
        var req = URLRequest(url: url)
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "Lookup", code: (resp as? HTTPURLResponse)?.statusCode ?? 0,
                          userInfo: [NSLocalizedDescriptionKey: "nothing found"])
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Citation details for a DOI (works for Crossref, DataCite/Zenodo and arXiv DOIs).
    static func csl(doi: String) async throws -> [String: Any] {
        let enc = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://doi.org/" + enc),
              let j = try await getJSON(url, accept: "application/vnd.citationstyles.csl+json") as? [String: Any]
        else { throw NSError(domain: "Lookup", code: 0, userInfo: [NSLocalizedDescriptionKey: "nothing found"]) }
        return j
    }

    /// Best Crossref match for a title (or any citation text).
    static func crossref(search: String) async throws -> [String: Any]? {
        var c = URLComponents(string: "https://api.crossref.org/works")!
        c.queryItems = [URLQueryItem(name: "query.bibliographic", value: search), URLQueryItem(name: "rows", value: "1")]
        guard let url = c.url, let j = try await getJSON(url) as? [String: Any],
              let msg = j["message"] as? [String: Any], let items = msg["items"] as? [[String: Any]] else { return nil }
        return items.first
    }

    struct Book { var title = "", authors: [String] = [], publisher = "", place = "", year = "" }

    /// Book details for an ISBN: Open Library first, then Google Books.
    static func book(isbn: String) async -> Book? {
        func year(_ s: String) -> String { s.range(of: "[0-9]{4}", options: .regularExpression).map { String(s[$0]) } ?? "" }
        if let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&format=json&jscmd=data"),
           let j = try? await getJSON(url) as? [String: Any], let d = j["ISBN:\(isbn)"] as? [String: Any] {
            var b = Book()
            b.title = (d["title"] as? String) ?? ""
            if let sub = d["subtitle"] as? String, !sub.isEmpty { b.title += ": " + sub }
            b.authors = ((d["authors"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
            b.publisher = ((d["publishers"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            b.place = ((d["publish_places"] as? [[String: Any]])?.first?["name"] as? String) ?? ""
            b.year = year((d["publish_date"] as? String) ?? "")
            if !b.title.isEmpty { return b }
        }
        if let url = URL(string: "https://www.googleapis.com/books/v1/volumes?q=isbn:\(isbn)"),
           let j = try? await getJSON(url) as? [String: Any],
           let v = (j["items"] as? [[String: Any]])?.first?["volumeInfo"] as? [String: Any] {
            var b = Book()
            b.title = (v["title"] as? String) ?? ""
            if let sub = v["subtitle"] as? String, !sub.isEmpty { b.title += ": " + sub }
            b.authors = (v["authors"] as? [String]) ?? []
            b.publisher = (v["publisher"] as? String) ?? ""
            b.year = year((v["publishedDate"] as? String) ?? "")
            if !b.title.isEmpty { return b }
        }
        return nil
    }

    /// "Kim Cascone" → "Cascone, Kim" (names that already have a comma are kept)
    static func lastFirst(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.contains(",") { return n }
        var parts = n.split(separator: " ").map(String.init)
        guard parts.count > 1 else { return n }
        let last = parts.removeLast()
        return last + ", " + parts.joined(separator: " ")
    }

    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        // ALL-CAPS titles from some publishers → Title Case
        if t.count > 12, t == t.uppercased(), t.contains(where: { $0.isLetter }) { t = t.capitalized }
        return t
    }

    /// What the first pages of a PDF tell us: an identifier, or a title to search for.
    struct Scan { var doi: String?; var arxiv: String?; var isbn: String?; var title: String? }

    static func scan(_ url: URL) -> Scan {
        var out = Scan()
        guard let doc = PDFDocument(url: url) else { return out }
        var text = ""
        for i in 0..<min(2, doc.pageCount) { text += (doc.page(at: i)?.string ?? "") + "\n" }
        let attrs = doc.documentAttributes ?? [:]
        let subject = (attrs[PDFDocumentAttribute.subjectAttribute] as? String) ?? ""
        out.doi = doi(in: subject) ?? doi(in: text)
        out.arxiv = arxiv(in: text)
        if out.doi == nil && out.arxiv == nil {
            var front = text
            if doc.pageCount > 2 {
                for i in 2..<min(8, doc.pageCount) { front += (doc.page(at: i)?.string ?? "") + "\n" }
            }
            out.isbn = isbnInText(front)
        }
        // a usable title: the PDF's own title if it looks real, else the first substantial line of page 1
        let meta = ((attrs[PDFDocumentAttribute.titleAttribute] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let junk = ["microsoft", "untitled", ".doc", ".pdf", ".tex", "word -", "layout"]
        if meta.count > 15, meta.split(separator: " ").count >= 3, !junk.contains(where: { meta.lowercased().contains($0) }) {
            out.title = meta
        } else if let line = (doc.page(at: 0)?.string ?? "").components(separatedBy: .newlines)
                    .map({ $0.trimmingCharacters(in: .whitespaces) })
                    .first(where: { $0.split(separator: " ").count >= 4 && $0.count < 200 }) {
            out.title = line
        }
        return out
    }
}

/// The state behind the Add card. (Its async methods run on the main thread, since they update the card.)
final class AddPaperModel: ObservableObject {
    let file: URL?
    @Published var status = ""
    @Published var busy = false
    @Published var lookupText = ""
    @Published var kind: EntryKind = .article
    @Published var authors = ""        // "Cascone, Kim; Menkman, Rosa"
    @Published var editors = ""
    @Published var title = ""
    @Published var year = ""
    @Published var container = ""      // journal / proceedings / book title / university
    @Published var publisher = ""
    @Published var place = ""
    @Published var volume = ""
    @Published var issue = ""
    @Published var pages = ""
    @Published var doi = ""
    @Published var isbn = ""
    @Published var url = ""
    @Published var move = true
    private var started = false

    init(file: URL?) {
        self.file = file
        if file == nil { kind = .book }
    }

    var fileInLibrary: Bool {
        guard let f = file?.standardizedFileURL.path else { return false }
        return f.hasPrefix(Paths.libraryFolder + "/")
    }

    @MainActor
    func start() async {
        guard !started else { return }
        started = true
        guard let f = file else {
            status = "Type the ISBN (or a DOI) and press Look Up, or fill in the details by hand."
            return
        }
        busy = true
        status = "Reading the PDF…"
        let found = await Task.detached { Lookup.scan(f) }.value
        busy = false
        if let d = found.doi {
            lookupText = d
            await lookUp()
        } else if let a = found.arxiv {
            lookupText = "arXiv:" + a
            await lookUp()
        } else if let i = found.isbn {
            lookupText = i
            await lookUp()
        } else if let t = found.title {
            lookupText = t
            await lookUp(titleSearch: true)
        } else {
            status = "No DOI found in the PDF. Paste a DOI, ISBN or arXiv ID above, or fill in the details by hand."
        }
    }

    @MainActor
    func lookUp(titleSearch: Bool = false) async {
        let s = lookupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            if let d = Lookup.doi(in: s) {
                status = "Looking up DOI \(d)…"
                apply(try await Lookup.csl(doi: d))
                status = "Found on doi.org. Check the details, then Add to Library."
            } else if let a = Lookup.arxiv(in: s) {
                status = "Looking up arXiv \(a)…"
                apply(try await Lookup.csl(doi: "10.48550/arXiv." + a))
                if container.isEmpty { container = "arXiv preprint arXiv:\(a)" }
                status = "Found on arXiv. Check the details, then Add to Library."
            } else if let i = Lookup.isbn(in: s) {
                status = "Looking up ISBN \(i)…"
                if let b = await Lookup.book(isbn: i) {
                    applyBook(b, isbn: i)
                    status = kind == .incollection
                        ? "Book details filled in. Add the chapter's title, author(s) and pages."
                        : "Found the book. Check the details, then Add to Library."
                } else {
                    status = "No book found for ISBN \(i). Fill in the details by hand."
                }
            } else {
                status = "Searching Crossref for “\(s.prefix(60))”…"
                if let item = try await Lookup.crossref(search: s) {
                    apply(item)
                    status = (titleSearch ? "No DOI in the PDF, so this is Crossref's best match for its title. " : "Crossref's best match. ")
                        + "Make sure it's the right paper!"
                } else {
                    status = "Nothing found. Fill in the details by hand."
                }
            }
        } catch {
            status = "Lookup didn't work (\(error.localizedDescription)). Check the internet connection, or fill in the details by hand."
        }
    }

    private func apply(_ j: [String: Any]) {
        func str(_ k: String) -> String {
            if let s = j[k] as? String { return Lookup.clean(s) }
            if let a = j[k] as? [String], let f = a.first { return Lookup.clean(f) }
            if let n = j[k] as? NSNumber { return n.stringValue }
            return ""
        }
        func names(_ k: String) -> String {
            ((j[k] as? [[String: Any]]) ?? []).compactMap { p -> String? in
                if let fam = p["family"] as? String {
                    let given = (p["given"] as? String) ?? ""
                    return given.isEmpty ? fam : "\(fam), \(given)"
                }
                if let lit = (p["literal"] as? String) ?? (p["name"] as? String) { return Lookup.lastFirst(lit) }
                return nil
            }.joined(separator: "; ")
        }
        kind = Lookup.kind(str("type"))
        title = str("title")
        let sub = str("subtitle")
        if !sub.isEmpty && !title.lowercased().contains(sub.lowercased()) { title += ": " + sub }
        authors = names("author")
        editors = names("editor")
        year = ""
        for k in ["issued", "published-print", "published-online", "published", "created"] {
            if let d = j[k] as? [String: Any], let parts = d["date-parts"] as? [[Any]], let y = parts.first?.first {
                let ys = "\(y)"
                if ys.count == 4 { year = ys; break }
            }
        }
        container = str("container-title")
        publisher = str("publisher")
        place = str("publisher-place")
        volume = str("volume")
        issue = str("issue")
        pages = str("page")
        doi = str("DOI")
        isbn = str("ISBN")
        url = doi.isEmpty ? str("URL") : ""
        if kind == .thesis && container.isEmpty { container = publisher; publisher = "" }
    }

    private func applyBook(_ b: Lookup.Book, isbn i: String) {
        let names = b.authors.map(Lookup.lastFirst).joined(separator: "; ")
        if kind == .incollection {
            container = b.title
            editors = names
        } else {
            kind = .book
            title = b.title
            authors = names
        }
        publisher = b.publisher
        place = b.place
        year = b.year
        isbn = i
        doi = ""
    }

    var firstLastName: String {
        let lead = authors.isEmpty ? editors : authors
        let first = lead.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return BibEntry.lastName(first)
    }

    func key(existing: Set<String>) -> String {
        CiteKey.make(lastName: firstLastName, year: year, title: title, existing: existing)
    }

    /// The BibTeX fields for the chosen type.
    var fields: [String: String] {
        func people(_ s: String) -> String {
            s.components(separatedBy: CharacterSet(charactersIn: ";\n")).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.joined(separator: " and ")
        }
        var f: [String: String] = ["title": title, "year": year]
        if !authors.isEmpty { f["author"] = people(authors) }
        switch kind {
        case .article:
            f["journal"] = container; f["volume"] = volume; f["number"] = issue; f["pages"] = pages
        case .inproceedings:
            f["booktitle"] = container; f["pages"] = pages; f["publisher"] = publisher; f["address"] = place
        case .book:
            f["publisher"] = publisher; f["address"] = place; f["isbn"] = isbn
            if !editors.isEmpty && authors.isEmpty { f["editor"] = people(editors) }
        case .incollection:
            f["booktitle"] = container; f["editor"] = people(editors); f["publisher"] = publisher
            f["address"] = place; f["pages"] = pages; f["isbn"] = isbn
        case .thesis:
            f["school"] = container
        case .misc:
            f["howpublished"] = container
        }
        if !doi.isEmpty { f["doi"] = doi } else if !url.isEmpty { f["url"] = url }
        return f.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}

/// The Add to Library card: what was found, editable, then one button.
struct AddPaperView: View {
    @EnvironmentObject var lib: Library
    @StateObject private var m: AddPaperModel

    init(file: URL?) {
        _m = StateObject(wrappedValue: AddPaperModel(file: file))
    }

    var key: String { m.key(existing: lib.bib.libraryKeys) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.file == nil ? "Add a Book or Chapter" : "Add to Library").font(.title2.weight(.semibold))
                Spacer()
                if let f = m.file {
                    Text(f.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: 260, alignment: .trailing)
                }
            }
            HStack(spacing: 8) {
                TextField("DOI, ISBN, arXiv ID or title", text: $m.lookupText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await m.lookUp() } }
                Button("Look Up") { Task { await m.lookUp() } }
                    .disabled(m.busy || m.lookupText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 8) {
                if m.busy { ProgressView().controlSize(.small) }
                Text(m.status).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(minHeight: 20, alignment: .leading)

            Form {
                Picker("Type", selection: $m.kind) {
                    ForEach(EntryKind.allCases) { Text($0.label).tag($0) }
                }
                TextField("Author(s)", text: $m.authors, prompt: Text("Last, First; Last, First"))
                if m.kind == .incollection || m.kind == .book {
                    TextField(m.kind == .book ? "Editor(s)" : "Book editor(s)", text: $m.editors, prompt: Text("Last, First; Last, First"))
                }
                TextField(m.kind == .incollection ? "Chapter title" : "Title", text: $m.title)
                TextField("Year", text: $m.year)
                if let label = m.kind.containerLabel {
                    TextField(label, text: $m.container)
                }
                if m.kind == .article {
                    HStack {
                        TextField("Volume", text: $m.volume)
                        TextField("Issue", text: $m.issue)
                    }
                }
                if [.article, .inproceedings, .incollection].contains(m.kind) {
                    TextField("Pages", text: $m.pages, prompt: Text("e.g. 12–34"))
                }
                if [.book, .incollection, .inproceedings].contains(m.kind) {
                    TextField("Publisher", text: $m.publisher)
                    TextField("Place", text: $m.place)
                }
                if [.book, .incollection].contains(m.kind) {
                    TextField("ISBN", text: $m.isbn)
                }
                TextField("DOI", text: $m.doi)
                if m.doi.isEmpty { TextField("URL", text: $m.url) }
            }
            .formStyle(.grouped)
            .frame(minHeight: 300)

            HStack(spacing: 6) {
                Text("Citation key").foregroundStyle(.secondary)
                Text("@" + key).font(.body.monospaced()).textSelection(.enabled)
            }
            if m.file != nil && !m.fileInLibrary {
                Toggle("Move the PDF into Papers/Library (uncheck to copy it instead)", isOn: $m.move)
                    .font(.callout)
            }
            HStack {
                Text(m.file == nil ? "Added to library.bib (no PDF)."
                     : "Saved as Papers/Library/\(key).pdf and added to library.bib.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { lib.addRequest = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Library") {
                    if lib.addToLibrary(type: m.kind.bibType, key: key, fields: m.fields, file: m.file, move: m.move) {
                        lib.addRequest = nil
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(m.title.trimmingCharacters(in: .whitespaces).isEmpty || m.busy)
            }
        }
        .padding(20)
        .frame(width: 600)
        .task { await m.start() }
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

    /// Added folders plus up to two levels of folders inside them (skipped when there are more than 40,
    /// e.g. Zotero's storage folders).
    func folderList() -> [Folder] {
        var roots: [(path: String, name: String)] = []
        if let st = prepare("SELECT path, name FROM folders") {
            while st.step() {
                let name = sqlite3_column_type(st.s, 1) == SQLITE_NULL ? nil : st.text(1)
                roots.append((st.text(0), name ?? DB.defaultName(st.text(0))))
            }
        }
        roots.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var paths: [String] = []
        if let st = prepare("SELECT path FROM files") { while st.step() { paths.append(st.text(0)) } }
        func sorted(_ names: [String]) -> [String] { names.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

        var out: [Folder] = []
        var seen = Set<String>()
        for root in roots {
            let prefix = root.path + "/"
            var count = 0
            var level1: [String: Int] = [:]
            var level2: [String: [String: Int]] = [:]
            for p in paths where p.hasPrefix(prefix) {
                count += 1
                let rel = p.dropFirst(prefix.count).split(separator: "/")
                guard rel.count >= 2 else { continue }
                let a = String(rel[0])
                level1[a, default: 0] += 1
                if rel.count >= 3 { level2[a, default: [:]][String(rel[1]), default: 0] += 1 }
            }
            if seen.insert(root.path).inserted {
                out.append(Folder(path: root.path, name: root.name, count: count))
            }
            guard level1.count <= 40 else { continue }
            for a in sorted(Array(level1.keys)) where seen.insert(prefix + a).inserted {
                out.append(Folder(path: prefix + a, name: a, count: level1[a] ?? 0, depth: 1, isRoot: false))
                guard let kids = level2[a], kids.count <= 40 else { continue }
                for b in sorted(Array(kids.keys)) where seen.insert(prefix + a + "/" + b).inserted {
                    out.append(Folder(path: prefix + a + "/" + b, name: b, count: kids[b] ?? 0, depth: 2, isRoot: false))
                }
            }
        }
        return out
    }

    /// Replace the "page 0" text (file name + bibliography details) of several files at once.
    func setNameRows(_ rows: [(Int, String)]) {
        exec("BEGIN")
        if let st = prepare("UPDATE fts SET body=? WHERE rowid=?") {
            for (id, text) in rows { st.bind([text, id * PAGE_SLOTS]); st.step(); st.reset() }
        }
        exec("COMMIT")
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
