// PDF Search — drag in PDFs, search every word, see the hits highlighted.
// One file, no dependencies: SwiftUI + PDFKit + the SQLite that ships with macOS.

import SwiftUI
import AppKit
import PDFKit
import QuartzCore
import SQLite3
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreText
import ImageIO

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
                Button("Add Book Pages from Photos…") { lib.choosePhotos() }
                Button("Add Folder to Search…") { lib.choose() }
                Divider()
                Button("Rescan Folders") { lib.refresh() }
                    .keyboardShortcut("r")
                Button(Marginalia.notesInVault ? "Open Paper Note in Obsidian" : "Open Paper Note") { lib.openNoteRequest += 1 }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                Button("Write Notes for All Annotated PDFs") { lib.exportAllMarginalia() }
                Button("Set Printed Page Number…") { Viewer.current?.askPageNumber() }
                Button("Open Book Photos Folder") { lib.openPhotoInbox() }
                Button("Clear Index…") { lib.confirmClear() }
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { Viewer.current?.undoLast() }
                    .keyboardShortcut("z")
                Button("Redo") { Viewer.current?.redoLast() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("PDF Search README") { lib.readmeRequest += 1 }
                    .keyboardShortcut("?", modifiers: .command)
            }
            CommandGroup(before: .toolbar) {
                Button("Zoom to Fit") { lib.zoomRequest += 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find in This PDF…") { lib.findRequest += 1 }
                    .keyboardShortcut("f")
                Button("Search My Notes") { lib.scope = Library.myNotesScope }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Button("Show Recently Edited") { lib.scope = Library.recentScope }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Show Recently Added") { lib.scope = Library.addedScope }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
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
        .windowResizability(.contentMinSize)
    }
}

/// PDF Search ▸ Settings (⌘,): where papers, library.bib and notes live.
struct SettingsView: View {
    @EnvironmentObject var lib: Library
    @State private var papers = Paths.papers
    @State private var bib = Paths.libraryBib
    @State private var notes = Paths.notesFolder
    @AppStorage("writeNotes") private var writeNotes = true
    @AppStorage("straightenPages") private var straightenPages = true
    @State private var claudeKey = ClaudeReader.key ?? ""
    @State private var style = MarkingStyle.load(from: Library.photoInbox)

    private var vaults: [ObsidianVaults.Vault] { ObsidianVaults.list() }
    /// the vault the notes folder is in, if any
    private var currentVault: ObsidianVaults.Vault? {
        vaults.first { notes == $0.path || notes.hasPrefix($0.path + "/") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                settingsRows
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 640, maxWidth: .infinity,
               minHeight: 360, idealHeight: 800, maxHeight: .infinity)
        .background(ResizableWindow(size: NSSize(width: 640, height: 800)))
    }

    @ViewBuilder private var settingsRows: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Obsidian vault").frame(width: 110, alignment: .leading)
                    Menu(currentVault?.name ?? "None") {
                        ForEach(vaults) { v in
                            Button(v.name + "   " + v.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                                lib.useVault(v.path)
                                notes = Paths.notesFolder; bib = Paths.libraryBib
                            }
                        }
                        if vaults.isEmpty { Text("No Obsidian vaults found on this Mac") }
                    }
                    .fixedSize()
                    Spacer()
                }
                Text("Choose your vault: paper notes go in its Literature folder, and library.bib in the vault. Or set the folders yourself below.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            row("Papers folder", papers, help: "Searched automatically. New papers go in its Library folder.") { path in
                set("papersFolder", path); papers = Paths.papers; lib.refresh()
            } reset: { set("papersFolder", nil); papers = Paths.papers; lib.refresh() }
            row("library.bib in", (bib as NSString).deletingLastPathComponent,
                help: "Your bibliography. Point Overleaf, Pandoc or Obsidian at this file.") { path in
                set("libraryBib", path + "/library.bib"); bib = Paths.libraryBib; lib.reloadBib(force: true)
            } reset: { set("libraryBib", nil); bib = Paths.libraryBib; lib.reloadBib(force: true) }
            Toggle("Write a Markdown note for each paper I annotate", isOn: $writeNotes)
                .toggleStyle(.checkbox)
            row("Notes folder", notes, help: "Plain Markdown files (@key.md): any notes app can open them. Obsidian users: a folder inside your vault.") { path in
                set("notesFolder", path); notes = Paths.notesFolder; lib.syncOwnNotesSoon()
            } reset: { set("notesFolder", nil); notes = Paths.notesFolder; lib.syncOwnNotesSoon() }
                .disabled(!writeNotes)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Claude API key").frame(width: 110, alignment: .leading)
                    SecureField("Paste your key here (optional)", text: $claudeKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: claudeKey) { k in ClaudeReader.setKey(k) }
                }
                Text("Optional. Paste a Claude API key here for higher-quality reading of book photos: exact quotes, handwriting, parentheses and page numbers. Your photos are sent to Anthropic, and use is billed to that key. Without a key, everything still works using your Mac's own text recognition, and nothing leaves this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Straighten pages in book photos", isOn: $straightenPages)
                    .toggleStyle(.checkbox)
                Text("Evens out bends and curved lines of print in new photos. Nothing is redrawn, so your marks stay. Books already made don't change.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("How you mark your books").font(.headline)
                Group {
                    Toggle("A yellow streak in the margin marks a passage", isOn: $style.marginStreaks)
                    Toggle("Pen underlines beside the streak pick out the exact words", isOn: $style.underlines)
                        .disabled(!style.marginStreaks)
                    Toggle("Big pen parentheses around a term make it a #tag", isOn: $style.parenthesisTags)
                    Toggle("I write in page numbers by hand", isOn: $style.handwrittenPageNumbers)
                }
                .toggleStyle(.checkbox)
                Text("Some pages have no printed number, such as the first page of a chapter, so citations need one from you. Write it at the top or bottom of the page (for example, p. 95 or pg. 95).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Any other habits (optional)").padding(.top, 4)
                Text("Only for what the boxes above don't cover, in your own words (for example, \u{201C}I circle names\u{201D} or \u{201C}a wavy line means I disagree\u{201D}). Claude reads this when it reads your pages.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("", text: $style.noteForClaude, axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...8)
                Text("For book photos. With everything off, photos become plain searchable pages. Kept in Book Photos/Marking Style.json, so it stays with your library.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .onChange(of: style) { s in
                if FileManager.default.fileExists(atPath: Paths.papers) { s.save(to: Library.photoInbox) }
            }
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
                Spacer(minLength: 8)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url { choose(url.standardizedFileURL.path) }
                }
                .fixedSize()
                Button("Default") { reset() }
                    .fixedSize()
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

/// SwiftUI gives the Settings window a fixed size. This lets it be resized,
/// and opens it big enough to show everything (or as tall as the screen allows).
struct ResizableWindow: NSViewRepresentable {
    let size: NSSize

    final class Probe: NSView {
        var wanted = NSSize.zero
        private var sized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let w = window else { return }
            w.styleMask.insert(.resizable)
            guard !sized, let screen = w.screen ?? NSScreen.main else { return }
            sized = true
            let room = screen.visibleFrame
            var f = w.frame
            let titleBar = f.height - w.contentLayoutRect.height
            let width = min(max(f.width, wanted.width), room.width)
            let height = min(max(f.height, wanted.height + titleBar), room.height)
            f.origin.y -= height - f.height     // the top edge stays where it is
            f.size = NSSize(width: width, height: height)
            if f.minY < room.minY { f.origin.y = room.minY }
            if f.maxX > room.maxX { f.origin.x = max(room.minX, room.maxX - f.width) }
            w.setFrame(f, display: true)
        }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.wanted = size
        return p
    }

    func updateNSView(_ view: Probe, context: Context) {
        DispatchQueue.main.async { view.apply() }
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
    @AppStorage("marginWidth") private var marginWidth: Double = 290
    @State private var showReadme = false
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
            viewer.highlightAndComment(.interesting)
        }
        .onChange(of: viewer.focusNoteID) { id in if id != nil { showMargin = true } }
        .onChange(of: viewer.spotlightNoteID) { id in if id != nil { showMargin = true } }
        .onChange(of: lib.linkRequest) { req in
            guard let req = req else { return }
            entryOnly = nil
            viewer.show(path: req.path, terms: [], page: req.page)
        }
        .onOpenURL { url in lib.handle([url]) }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { lib.offerVaultIfNeeded() } }
        .sheet(item: $lib.addRequest, onDismiss: { lib.nextAdd() }) { req in
            AddPaperView(file: req.file).environmentObject(lib)
        }
        .onChange(of: lib.citeTexRequest) { _ in cite(.latex) }
        .onChange(of: lib.zoomRequest) { _ in viewer.zoomToFit() }
        .onChange(of: lib.openNoteRequest) { _ in openPaperNote() }
        .onChange(of: lib.readmeRequest) { _ in showReadme = true }
        .sheet(isPresented: $showReadme) { ReadmeCard() }
        .task(id: findText) {
            guard showFind else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let p = viewer.path else { return }
            viewer.show(path: p, terms: activeTerms, page: 0, wholeWords: !findMode)
        }
    }

    // Sidebar: results list + status line
    var searchPrompt: String {
        if inMyNotes { return "Search your notes" }
        if inRecent { return "Search recently edited papers" }
        if inAdded { return "Search recently added papers" }
        if let s = lib.scope, let f = lib.folders.first(where: { $0.path == s }) { return "Search \(f.name)" }
        return "Search everything"
    }
    var scopeFolder: Folder? { lib.scope.flatMap { s in lib.folders.first { $0.path == s } } }
    var inMyNotes: Bool { lib.scope == Library.myNotesScope }
    var inRecent: Bool { lib.scope == Library.recentScope }
    var inAdded: Bool { lib.scope == Library.addedScope }

    /// the entry behind the first selected result
    func entryFor(_ ids: Set<Int>) -> BibEntry? {
        guard let id = ids.first, let h = lib.results.first(where: { $0.id == id }) else { return nil }
        return h.entry ?? (h.path.isEmpty ? nil : lib.bib.entry(forPath: h.path))
    }

    var scopeBar: some View {
        HStack(spacing: 6) {
            Picker("Search in", selection: $lib.scope) {
                Text("Everything (\(lib.docCount))").tag(String?.none)
                Label("My Notes", systemImage: "highlighter").tag(Optional(Library.myNotesScope))
                Label("Recently Edited", systemImage: "clock").tag(Optional(Library.recentScope))
                Label("Recently Added", systemImage: "plus.circle").tag(Optional(Library.addedScope))
                Divider()
                ForEach(lib.folders) { f in
                    Text(verbatim: String(repeating: "\u{2003}", count: f.depth) + "\(f.name)  (\(f.count))")
                        .tag(Optional(f.path))
                }
            }
            .pickerStyle(.menu)
            Menu {
                if inMyNotes {
                    Button("Show Notes Folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: Paths.notesFolder)])
                    }
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
            .disabled(lib.scope == nil || inRecent || inAdded)
            .help("Folder or notes options")
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
                    if let h = hitFor(ids), let n = h.note, !n.quoteText.isEmpty {
                        Button("Copy Quote with Citation") {
                            lib.copyQuote(n.quoteText, pageLabel: n.pageLabel, entry: h.entry, path: h.path.isEmpty ? nil : h.path)
                        }
                    }
                    Button("Copy Citation [@key]") { citeHit(ids, .pandoc) }
                    Button("Copy Obsidian Link [[@key]]") { citeHit(ids, .obsidianLink) }
                    Button("Copy LaTeX Citation \\cite{key}") { citeHit(ids, .latex) }
                    if let h = hitFor(ids), !(h.path.isEmpty && h.entry == nil) {
                        Button(Marginalia.notesInVault ? "Open in Obsidian" : "Open Paper Note") { lib.openPaperNote(for: h) }
                    }
                    Divider()
                    if let id = ids.first, let h = lib.results.first(where: { $0.id == id }), !h.path.isEmpty, h.entry == nil {
                        Button("Look Up Citation Details…") { lib.requestAdd([URL(fileURLWithPath: h.path)]) }
                    }
                    Button("Open in Preview") { openFiles(ids) }
                    Button("Show in Finder") { reveal(ids) }
                    if !inMyNotes {
                        Divider()
                        Button("Remove from Index") { lib.remove(Array(ids).filter { $0 > 0 }) }
                    }
                } primaryAction: { ids in
                    // double-click: a paragraph from your Obsidian note opens that note; anything else opens the PDF
                    if let h = hitFor(ids), h.note?.kind == "o", let p = h.note?.notePath {
                        Marginalia.openNote(p)
                    } else {
                        openFiles(ids)
                    }
                }
                .overlay {
                    if lib.results.isEmpty && !lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(inMyNotes ? "No notes match" : "No matches").foregroundStyle(.secondary)
                    } else if lib.results.isEmpty && inRecent {
                        Text("Nothing yet.\nPapers you highlight or write notes in\nappear here, newest first.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    } else if lib.results.isEmpty && inAdded {
                        Text("Nothing yet.\nPapers and books you add\nappear here, newest first.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    } else if lib.results.isEmpty && inMyNotes {
                        Text("No notes yet.\nSelect text in a PDF and press H.")
                            .multilineTextAlignment(.center).foregroundStyle(.secondary)
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
                    Button("Add Book Pages from Photos…") { lib.choosePhotos() }
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
                Text(f).foregroundStyle(.primary).lineLimit(5).fixedSize(horizontal: false, vertical: true)
            } else if let p = lib.progress {
                ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    .frame(width: 70)
                Text("Indexing \(p.done) of \(p.total)…")
            } else if let err = lib.errorMessage {
                Text(err).foregroundStyle(.red)
            } else if inAdded {
                Text(lib.results.count == 1 ? "1 paper recently added" : "\(lib.results.count) papers recently added")
            } else if inRecent {
                Text(lib.results.count == 1 ? "1 paper you've worked on" : "\(lib.results.count) papers you've worked on")
            } else if inMyNotes {
                if lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(lib.results.count == 1 ? "1 paper with notes" : "\(lib.results.count) papers with notes")
                } else {
                    Text(lib.results.count == 1 ? "1 note" : "\(lib.results.count) notes")
                }
            } else if lib.query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("\(lib.results.count) items")
            } else {
                Text("\(lib.results.count) matches")
            }
            Spacer()
            Button("README") { showReadme = true }
                .buttonStyle(.link)
                .font(.caption)
                .help("How PDF Search is meant to be used, in one page (also Help ▸ PDF Search README, ⌘?)")
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
                ColumnHandle(width: $marginWidth, range: 220...600)
                MarginColumn(viewer: viewer)
                    .frame(width: marginWidth)
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
            // a little space between the sidebar's edge and the PDF, so the PDF view doesn't
            // fight the column-resize cursor
            .padding(.leading, 6)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle(entryOnly?.shortCite ?? currentEntry?.shortCite ?? viewer.title)
            .toolbar {
                ToolbarItemGroup {
                    // match arrows: only while there are matches to step through
                    if viewer.matchCount > 0 {
                        Button { viewer.step(-1) } label: { Label("Previous Match", systemImage: "chevron.left") }
                            .keyboardShortcut("g", modifiers: [.command, .shift])
                            .help("Previous match (⇧⌘G)")
                        Text("\(viewer.matchIndex + 1) of \(viewer.matchCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button { viewer.step(1) } label: { Label("Next Match", systemImage: "chevron.right") }
                            .keyboardShortcut("g", modifiers: .command)
                            .help("Next match (⌘G)")
                    }
                    Menu {
                        Section("Copy to the clipboard, then paste:") {
                            Button("[@key]   a citation in Obsidian / Pandoc   ⇧⌘C") { cite(.pandoc) }
                            Button("[[@key]]   a link to this paper's note in Obsidian") { cite(.obsidianLink) }
                            Button("\\cite{key}   a citation in LaTeX / Overleaf   ⌥⇧⌘C") { cite(.latex) }
                            Button("key   just the citation key") { cite(.key) }
                        }
                    } label: {
                        Text("Copy Citation")
                    }
                        .menuIndicator(.visible)
                        .disabled(viewer.path == nil && entryOnly == nil)
                        .help("Copy this paper's citation or Obsidian link, then paste it into your writing")
                    Button { openPaperNote() } label: { Text(Marginalia.notesInVault ? "Open in Obsidian" : "Open Note") }
                        .disabled(viewer.path == nil && entryOnly == nil)
                        .help("Open this paper's note (your highlights and notes, as Markdown), creating it if needed (⌥⌘O)")
                    Toggle(isOn: $showMargin) { Text("Notes") }
                        .toggleStyle(.button)
                        .help("Show or hide the notes column (your highlights and notes)")
                    Menu {
                        Button("Zoom to Fit  ⌘0") { viewer.zoomToFit() }
                            .disabled(viewer.path == nil)
                        Button("Open in Preview") {
                            if let p = viewer.path { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                        }
                            .disabled(viewer.path == nil)
                        Button("Show in Finder") {
                            if let p = viewer.path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)]) }
                        }
                            .disabled(viewer.path == nil)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                        .disabled(viewer.path == nil && entryOnly == nil)
                        .help("More: zoom to fit, open in Preview, show in Finder")
                }
            }
    }

    /// Open (and if needed create) the Markdown note for what's on screen.
    func openPaperNote() {
        viewer.flushSave()
        if let p = viewer.path { lib.openPaperNote(pdf: p) }
        else if let e = entryOnly { lib.openPaperNote(entry: e) }
    }

    // MARK: actions

    func showSelected() {
        guard let id = selection, let hit = lib.results.first(where: { $0.id == id }) else { return }
        if hit.path.isEmpty {
            entryOnly = hit.entry
            viewer.close()
        } else if let n = hit.note, n.kind != "o" {
            // one of your notes: open its page and point at its card in the notes column
            entryOnly = nil
            viewer.show(path: hit.path, terms: activeTerms, page: hit.page, wholeWords: !findMode,
                        note: NoteTarget(page: n.pageIndex, quote: n.quoteText, comment: n.commentText, isSummary: n.kind == "s"))
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

    func hitFor(_ ids: Set<Int>) -> Hit? {
        guard let id = ids.first else { return nil }
        return lib.results.first(where: { $0.id == id })
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
    /// a picture for entries without a PDF
    private var symbol: String {
        if !hit.path.isEmpty { return "doc" }
        switch hit.entry?.type ?? "" {
        case "book": return "book.closed"
        case "incollection", "inbook": return "book"
        default: return "doc.text"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumb(path: hit.path, isbn: hit.entry.flatMap { $0.type == "book" || hit.path.isEmpty ? Thumbnails.isbns($0.fields["isbn"]) : nil },
                  symbol: symbol,
                  book: hit.path.isEmpty ? nil : hit.entry.flatMap { $0.type == "book" ? $0.title + "|" + ($0.people.first.map(BibEntry.lastName) ?? "") : nil })
                .padding(.top, 2)
            details
        }
    }
    var details: some View {
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
            if let n = hit.note {
                // one of your notes (Search in ▸ My Notes)
                if n.kind == "e" {
                    Label("Essential", systemImage: "star.fill").font(.caption.weight(.semibold))
                        .foregroundStyle(Color(nsColor: HighlightLevel.essential.nsColor.withAlphaComponent(1)))
                } else if n.kind == "s" {
                    Text("About this paper").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                } else if n.kind == "o" {
                    Text("In your paper note").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                if let q = n.quote {
                    Text(q).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                        .padding(.leading, 9)
                        .overlay(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color(nsColor: (n.kind == "e" ? HighlightLevel.essential : .interesting).nsColor.withAlphaComponent(0.9)))
                                .frame(width: 3)
                        }
                }
                if let c = n.comment {
                    Text(c).font(.callout).lineLimit(5)
                }
            } else if let s = hit.snippet {
                Text(s).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            if let ns = hit.noteSnippet {
                // a normal search that also matched your notes on this paper
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "highlighter").font(.caption).foregroundStyle(.orange)
                    Text(ns).font(.callout).lineLimit(3)
                }
                if hit.noteCount > 1 {
                    Text("+ \(hit.noteCount - 1) more of your notes").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !hit.path.isEmpty {
                Text(hit.folder).font(.caption2).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.head)
            }
        }
        .padding(.vertical, 3)
    }
}

/// README: how the app is meant to be used, in plain English, on one page (Help ▸ PDF Search README, ⌘?,
/// or the README link under the results).
struct ReadmeCard: View {
    @Environment(\.dismiss) private var dismiss
    private let steps: [(String, String)] = [
        ("Add a paper",
         "Drag a PDF onto the window. Check the citation details on the card, then click Add to Library. The PDF is filed in your Papers folder."),
        ("Add book pages",
         "Put photos of book pages in the Book Photos folder (File ▸ Open Book Photos Folder), and PDF Search takes them by itself. They become a searchable PDF of the book, in page order. Add one book at a time, or start each book’s photos with its copyright page. A new book always needs its copyright page."),
        ("Find",
         "Type words: a PDF must contain them all, anywhere in it (capitals don’t matter). Put \"quotes\" around an exact phrase. Use “Search in” to narrow it: a folder, My Notes (only what you’ve written), or Recently Edited (papers you’ve worked on)."),
        ("Read",
         "Click a result. Your search words are marked in orange; ⌘G jumps to the next one."),
        ("Highlight",
         "Select a passage and press H, then type your thought in the box on the right. Tick Essential for the few passages that matter most. Add #tags (e.g. #improvisation) to group ideas across papers; click a tag to see them all, here or in Obsidian."),
        ("Your notes stay with the PDF",
         "Highlights and notes are saved inside the PDF itself, and copied automatically into the paper’s note in Obsidian."),
        ("Think and write in Obsidian",
         "Click Open in Obsidian to go to the paper’s note and write your own thoughts under “Notes”. For a project, make a note and paste links to its papers (Copy Citation ▸ [[@key]])."),
        ("Cite",
         "Copy Citation gives you [@key] for Obsidian and Pandoc, or \\cite{key} for LaTeX and Overleaf."),
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("How PDF Search works").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 11) {
                ForEach(steps.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(i + 1)").font(.callout.monospacedDigit().weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(steps[i].0).font(.headline)
                            Text(steps[i].1).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack {
                Text("The full manual is “PDF Search Manual” in your Obsidian vault.").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 520)
    }
}

/// A #tag under a note: click to see every note with that tag (in My Notes). The same tag works in Obsidian.
struct TagChip: View {
    let tag: String
    var body: some View {
        Button { Library.shared.showTag(tag) } label: {
            Text("#" + tag)
                .font(.caption)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Show every note tagged #\(tag)")
    }
}

/// Lays its children out left to right, wrapping onto new lines (for tag chips).
struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

/// A draggable divider for the notes column: a 9-pt-wide grab area with a hairline in the middle, which
/// keeps showing the resize cursor (the PDF view next to it would otherwise keep resetting the cursor).
struct ColumnHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 4)
            .background(Color(nsColor: .windowBackgroundColor))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if startWidth == nil { startWidth = width }
                        NSCursor.resizeLeftRight.set()
                        // dragging left makes the notes column wider
                        width = min(range.upperBound, max(range.lowerBound, (startWidth ?? width) - v.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the notes column")
    }
}

/// The little picture at the left of a result: page 1 of the PDF (a book's cover, a paper's first page),
/// a book's cover from Open Library for entries without a PDF, or a symbol.
struct Thumb: View {
    let path: String
    let isbn: String?
    let symbol: String
    var book: String? = nil     // "title|author", to search for a cover when there's no ISBN to go on
    @State private var image: NSImage?
    @State private var loadedKey = ""

    var body: some View {
        ZStack {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.08))
                    .overlay(Image(systemName: symbol).foregroundStyle(.tertiary))
            }
        }
        .frame(width: 36, height: 48)
        // .task(id:), not .onChange: an onChange closure still sees the old values, so a book's details arriving
        // after the row was drawn never reached load()
        .task(id: path + "|" + (isbn ?? "") + "|" + (book ?? "")) { load() }
    }

    private func load() {
        let key = path + "|" + (isbn ?? "") + "|" + (book ?? "")
        guard key != loadedKey else { return }
        loadedKey = key
        image = nil
        Thumbnails.shared.image(pdf: path.isEmpty ? nil : path, isbn: isbn, book: book) { img in
            if loadedKey == key { image = img }
        }
    }
}

/// Makes and caches the result pictures (~/Library/Caches/PDF Search/Thumbnails). A PDF's picture is
/// remade when the file changes; covers that Open Library doesn't have are remembered as missing.
final class Thumbnails {
    static let shared = Thumbnails()
    private let memory = NSCache<NSString, NSImage>()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 3
        q.qualityOfService = .utility
        return q
    }()
    private let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Search/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var waiting: [String: [(NSImage?) -> Void]] = [:]   // main thread only

    init() { memory.countLimit = 800 }

    /// The first ISBN in a bibliography field ("978-0-262-01234-5; 0262…").
    static func isbn(_ field: String?) -> String? {
        guard let f = field else { return nil }
        for token in f.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "/" }) {
            if let i = Lookup.isbn(in: String(token)) { return i }
        }
        return Lookup.isbn(in: f)
    }

    /// Every ISBN in a bibliography field, separated by spaces, or nil if there are none.
    static func isbns(_ field: String?) -> String? {
        guard let f = field else { return nil }
        let all = f.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "/" }).compactMap { Lookup.isbn(in: String($0)) }
        return all.isEmpty ? Lookup.isbn(in: f) : all.joined(separator: " ")
    }

    /// Calls back on the main thread with the picture, or nil.
    func image(pdf path: String?, isbn: String?, book: String? = nil, done: @escaping (NSImage?) -> Void) {
        let key: String
        if let p = path {
            let a = try? FileManager.default.attributesOfItem(atPath: p)
            let m = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let s = (a?[.size] as? NSNumber)?.intValue ?? 0
            key = "pdf|\(p)|\(m)|\(s)" + (isbn == nil && book == nil ? "" : "|cover2|" + (isbn ?? ""))
        } else if let i = isbn {
            key = "isbn|\(i)"
        } else {
            done(nil)
            return
        }
        if let img = memory.object(forKey: key as NSString) { done(img); return }
        if waiting[key] != nil { waiting[key]?.append(done); return }
        waiting[key] = [done]
        let name = Thumbnails.hash(key)
        let file = dir.appendingPathComponent(name + ".jpg")
        let none = dir.appendingPathComponent(name + ".none")
        queue.addOperation {
            let fm = FileManager.default
            var data: Data?
            if let d = try? Data(contentsOf: file) {
                data = d
            } else if !fm.fileExists(atPath: none.path) {
                if let p = path {
                    // a book shows its real cover, unless you photographed the cover yourself
                    var cover: Cover = .missing
                    if isbn != nil || book != nil, !BookPhotos.hasCover(URL(fileURLWithPath: p)) { cover = Thumbnails.cover(isbn ?? "", book: book) }
                    if case .found(let d) = cover { data = d }
                    else { data = autoreleasepool { Thumbnails.render(p) } }
                    if data == nil { fm.createFile(atPath: none.path, contents: nil) }
                    if case .offline = cover {     // show the page for now; look for the cover again another time
                        let img = data.flatMap { NSImage(data: $0) }
                        DispatchQueue.main.async {
                            let calls = self.waiting.removeValue(forKey: key) ?? []
                            for c in calls { c(img) }
                        }
                        return
                    }
                } else if let i = isbn {
                    switch Thumbnails.cover(i) {
                    case .found(let d): data = d
                    case .missing: fm.createFile(atPath: none.path, contents: nil)
                    case .offline: break          // try again another time
                    }
                }
                if let d = data { try? d.write(to: file) }
            }
            let img = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                if let img = img { self.memory.setObject(img, forKey: key as NSString) }
                let calls = self.waiting.removeValue(forKey: key) ?? []
                for c in calls { c(img) }
            }
        }
    }

    /// FNV-1a, for cache file names
    static func hash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Page 1 as a small JPEG on white.
    static func render(_ path: String) -> Data? {
        guard let doc = PDFDocument(url: URL(fileURLWithPath: path)), !doc.isLocked,
              let page = doc.page(at: 0) else { return nil }
        var box = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { box = NSSize(width: box.height, height: box.width) }
        guard box.width > 1, box.height > 1 else { return nil }
        // 160 px on the long side: sharp at 36 × 48 pt on a Retina screen
        let scale = 160 / max(box.width, box.height)
        let w = max(1, Int((box.width * scale).rounded())), h = max(1, Int((box.height * scale).rounded()))
        let thumb = page.thumbnail(of: NSSize(width: w, height: h), for: .cropBox)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let r = NSRect(x: 0, y: 0, width: w, height: h)
        NSColor.white.setFill()
        r.fill()
        thumb.draw(in: r)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }

    enum Cover { case found(Data), missing, offline }

    /// A book cover from Open Library (no picture → .missing; no connection → .offline).
    /// Tries each ISBN (hardback and paperback often differ) at Open Library and Google Books, then, for a
    /// `book` ("title|author"), a search by title and author.
    static func cover(_ isbns: String, book: String? = nil) -> Cover {
        var offline = false
        func tried(_ c: Cover) -> Data? {
            switch c {
            case .found(let d): return d
            case .offline: offline = true; return nil
            case .missing: return nil
            }
        }
        let list = isbns.split(separator: " ").map(String.init)
        for i in list { if let d = tried(picture("https://covers.openlibrary.org/b/isbn/\(i)-M.jpg?default=false")) { return .found(d) } }
        for i in list { if let d = tried(googleCover("isbn:" + i)) { return .found(d) } }
        if let parts = book?.components(separatedBy: "|"), parts.count == 2 {
            let title = parts[0].components(separatedBy: CharacterSet(charactersIn: ":;")).first ?? parts[0]
            if let d = tried(openLibrarySearch(title: title, author: parts[1])) { return .found(d) }
            if let d = tried(googleCover("intitle:" + title + (parts[1].isEmpty ? "" : " inauthor:" + parts[1]))) { return .found(d) }
        }
        return offline ? .offline : .missing
    }

    private static func fetch(_ url: URL) -> (data: Data?, status: Int?) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(Lookup.userAgent, forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: (data: Data?, status: Int?) = (nil, nil)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            out = (d, (r as? HTTPURLResponse)?.statusCode)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 20)
        return out
    }

    private static func picture(_ address: String) -> Cover {
        guard let url = URL(string: address) else { return .missing }
        let (d, s) = fetch(url)
        if s == 200, let d = d, d.count > 500, NSImage(data: d) != nil { return .found(d) }
        return s == nil ? .offline : .missing
    }

    private static func googleCover(_ query: String) -> Cover {
        var c = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")
        c?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let api = c?.url else { return .missing }
        let (body, status) = fetch(api)
        guard status != nil else { return .offline }
        guard let b = body, let j = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any],
              let items = j["items"] as? [[String: Any]] else { return .missing }
        for item in items {
            if let v = item["volumeInfo"] as? [String: Any], let links = v["imageLinks"] as? [String: Any],
               let t = links["thumbnail"] as? String {
                return picture(t.replacingOccurrences(of: "http://", with: "https://"))
            }
        }
        return .missing
    }

    private static func openLibrarySearch(title: String, author: String) -> Cover {
        var c = URLComponents(string: "https://openlibrary.org/search.json")
        c?.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "author", value: author),
                         URLQueryItem(name: "fields", value: "cover_i"), URLQueryItem(name: "limit", value: "5")]
        guard let api = c?.url else { return .missing }
        let (body, status) = fetch(api)
        guard status != nil else { return .offline }
        guard let b = body, let j = (try? JSONSerialization.jsonObject(with: b)) as? [String: Any],
              let docs = j["docs"] as? [[String: Any]],
              let id = docs.compactMap({ $0["cover_i"] as? Int }).first else { return .missing }
        return picture("https://covers.openlibrary.org/b/id/\(id)-M.jpg?default=false")
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
                Button("Copy [[@\(entry.key)]]") { cite(.obsidianLink) }
                Button("Copy \\cite{\(entry.key)}") { cite(.latex) }
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

/// Two kinds of highlight. The level *is* the colour in the PDF, so other PDF apps show it too:
/// yellow = Interesting (the everyday kind), any other colour = Essential (the few passages that matter most).
enum HighlightLevel: String, CaseIterable, Identifiable {
    case essential, interesting
    var id: String { rawValue }
    var name: String { self == .essential ? "Essential" : "Interesting" }
    var nsColor: NSColor {
        switch self {
        // solid colours: PDF files don't keep a highlight's transparency, so a see-through colour looks
        // different after every save. These are the old half-transparent colours, already mixed with white.
        case .essential:   return NSColor(srgbRed: 0.98, green: 0.665, blue: 0.725, alpha: 1)
        case .interesting: return NSColor(srgbRed: 1.00, green: 0.93, blue: 0.55, alpha: 1)
        }
    }
    /// Highlights saved before the colours went solid show at full strength; this gives them today's colour.
    /// (On screen only, until the PDF is next saved.)
    static func refreshColor(_ a: PDFAnnotation) {
        guard (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Highlight",
              let c = a.color.usingColorSpace(.sRGB) else { return }
        func near(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> Bool {
            abs(c.redComponent - r) < 0.02 && abs(c.greenComponent - g) < 0.02 && abs(c.blueComponent - b) < 0.02
        }
        if near(1, 0.86, 0.10) { a.color = interesting.nsColor }
        else if near(0.96, 0.33, 0.45) { a.color = essential.nsColor }
    }
    /// Highlights, underlines etc.: yellow → Interesting, other colours → Essential. Notes (sticky notes) have no level.
    static func of(_ a: PDFAnnotation) -> HighlightLevel? {
        let t = (a.type ?? "").replacingOccurrences(of: "/", with: "")
        guard ["Highlight", "Underline", "StrikeOut", "Squiggly"].contains(t) else { return nil }
        return isYellow(a.color) ? .interesting : .essential
    }
    static func isYellow(_ c: NSColor) -> Bool {
        guard let rgb = c.usingColorSpace(.sRGB) ?? c.usingColorSpace(.deviceRGB) else { return true }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // no colour at all counts as the everyday kind; grey or any real hue outside yellow is Essential
        if rgb.redComponent == 0 && rgb.greenComponent == 0 && rgb.blueComponent == 0 && a == 0 { return true }
        return s >= 0.15 && h >= 0.11 && h < 0.20
    }
}

/// PDFView with "Highlight" / "Remove Highlight" in its right-click menu.
final class HighlightingPDFView: PDFView {
    var onHighlightAndNote: ((PDFSelection, HighlightLevel) -> Void)?
    var onRemove: ((PDFAnnotation) -> Void)?
    var onEditNote: ((PDFAnnotation) -> Void)?
    var onSetLevel: ((PDFAnnotation, HighlightLevel) -> Void)?

    static func isHighlight(_ a: PDFAnnotation) -> Bool {
        (a.type ?? "").replacingOccurrences(of: "/", with: "") == "Highlight"
    }

    /// H highlights the selected text (as Interesting; tick Essential on its card to change that).
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, event.charactersIgnoringModifiers?.lowercased() == "h",
           let sel = currentSelection, let t = sel.string, t.contains(where: { !$0.isWhitespace }) {
            onHighlightAndNote?(sel, .interesting)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        var extra: [NSMenuItem] = []
        if let sel = currentSelection, let text = sel.string, text.contains(where: { !$0.isWhitespace }) {
            let item = NSMenuItem(title: "Highlight", action: #selector(noteSelectionItem(_:)), keyEquivalent: "")
            item.target = self
            extra.append(item)
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
                if let level = HighlightLevel.of(ann) {
                    let other: HighlightLevel = level == .essential ? .interesting : .essential
                    let mark = NSMenuItem(title: "Mark as \(other.name)", action: #selector(setLevelItem(_:)), keyEquivalent: "")
                    mark.target = self
                    mark.representedObject = [ann, other.rawValue] as [Any]
                    extra.append(mark)
                }
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

    @objc private func removeHighlightItem(_ sender: NSMenuItem) {
        if let ann = sender.representedObject as? PDFAnnotation { onRemove?(ann) }
    }
    @objc private func noteSelectionItem(_ sender: NSMenuItem) {
        let level = HighlightLevel(rawValue: sender.representedObject as? String ?? "") ?? .interesting
        if let sel = currentSelection { onHighlightAndNote?(sel, level) }
    }
    @objc private func setLevelItem(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Any], pair.count == 2,
              let ann = pair[0] as? PDFAnnotation, let raw = pair[1] as? String,
              let level = HighlightLevel(rawValue: raw) else { return }
        onSetLevel?(ann, level)
    }
    @objc private func editNoteItem(_ sender: NSMenuItem) {
        if let ann = sender.representedObject as? PDFAnnotation { onEditNote?(ann) }
    }
}

final class Viewer: ObservableObject {
    /// the app's one viewer, so menu commands and background work can reach it
    private(set) static weak var current: Viewer?
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

    private var unsaved = false
    private var saveWork: DispatchWorkItem?
    /// highlights / notes in the open PDF, in page order (shown in the margin column)
    @Published private(set) var notes: [MarginNote] = []
    /// the note card to scroll to and put the cursor in
    @Published var focusNoteID: ObjectIdentifier?
    /// the note card to scroll to and outline, without taking the keyboard (a My Notes result)
    @Published var spotlightNoteID: ObjectIdentifier?
    /// true while text is selected in the PDF (shows the Highlight button)
    @Published private(set) var hasSelection = false
    /// notes about the whole paper (stored in the PDF as a page-1 note starting with "Summary")
    @Published private(set) var summary = ""
    /// bumped each time a document finishes loading (resets the summary box)
    @Published private(set) var docGen = 0

    init() {
        Viewer.current = self
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
        pdfView.onHighlightAndNote = { [weak self] _, level in self?.highlightAndComment(level) }
        pdfView.onSetLevel = { [weak self] ann, level in self?.setLevel(ann, level) }
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
                self.spotlightNoteID = ObjectIdentifier(ann)
                self.focusNoteID = ObjectIdentifier(ann)
            }
            return event
        }
    }

    // MARK: highlights (saved into the PDF file, like Preview)

    /// H, the Highlight button or ⌃⌘H: highlight the selected text and put the cursor in its note.
    func highlightAndComment(_ level: HighlightLevel = .interesting) {
        guard let sel = pdfView.currentSelection, let text = sel.string, text.contains(where: { !$0.isWhitespace }) else {
            Library.shared.showFlash("Select some text in the PDF first, then press H")
            return
        }
        let made = addHighlight(sel, level: level)
        hasSelection = false
        if let a = made.first { focusNoteID = ObjectIdentifier(a) }
    }

    /// Store a note in its highlight (the PDF's own comment field, so every PDF app shows it).
    /// Called as you type; the PDF is saved a moment after you stop.
    func updateComment(_ note: MarginNote, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = BookMarks.splitContents(note.annotation.contents ?? "")
        guard parts.note != t else { return }
        note.annotation.contents = BookMarks.joinContents(note: t, quote: parts.quote)
        note.annotation.modificationDate = Date()
        markUnsaved(after: 1.5)
    }

    /// The Edit button on a photo highlight: corrects the text read from the page. Empty goes back to what was read.
    func updateQuote(_ note: MarginNote, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = BookMarks.splitContents(note.annotation.contents ?? "")
        guard (parts.quote ?? "") != t else { return }
        note.annotation.contents = BookMarks.joinContents(note: parts.note, quote: t)
        note.annotation.modificationDate = Date()
        markUnsaved(after: 1.5)
        refreshNotes()
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

    /// Make a highlight Essential or Interesting (changes its colour in the PDF).
    func setLevel(_ ann: PDFAnnotation, _ level: HighlightLevel) {
        guard let before = HighlightLevel.of(ann), before != level else { return }
        ann.color = level.nsColor
        ann.modificationDate = Date()
        pdfView.undoManager?.registerUndo(withTarget: self) { v in v.setLevel(ann, before) }
        pdfView.undoManager?.setActionName("Mark as \(level.name)")
        markUnsaved()
        refreshNotes()
    }

    /// Scroll to a highlight, outline its card, and briefly outline it in the PDF.
    func reveal(_ note: MarginNote) {
        guard let page = note.annotation.page else { return }
        // scroll only if the highlight isn't already fully on screen (so clicking into a note box doesn't jump)
        let onScreen = pdfView.convert(note.annotation.bounds, from: page)
        if !pdfView.bounds.contains(onScreen) || pdfView.currentPage == nil {
            pdfView.go(to: note.annotation.bounds.insetBy(dx: -40, dy: -80), on: page)
        }
        spotlightNoteID = note.id
        let ann = note.annotation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.flash(ann) }
    }

    private var flashView: NSView?

    /// A thin dark outline around an annotation that fades in and out quickly (drawn over the page, never saved).
    func flash(_ ann: PDFAnnotation) {
        guard let page = ann.page, let docView = pdfView.documentView else { return }
        flashView?.removeFromSuperview()
        let viewRect = pdfView.convert(ann.bounds.insetBy(dx: -3, dy: -3), from: page)
        let v = NSView(frame: docView.convert(viewRect, from: pdfView))
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.black.withAlphaComponent(0.7).cgColor
        v.layer?.borderWidth = 1.5
        v.layer?.cornerRadius = 3
        v.alphaValue = 0
        docView.addSubview(v)
        flashView = v
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            v.animator().alphaValue = 1
        }, completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    v.animator().alphaValue = 0
                }, completionHandler: {
                    v.removeFromSuperview()
                    if self.flashView === v { self.flashView = nil }
                })
            }
        })
    }

    func refreshNotes() {
        notes = pdfView.document.map(Marginalia.collect) ?? []
        notes.forEach { HighlightLevel.refreshColor($0.annotation) }
    }

    @discardableResult
    func addHighlight(_ sel: PDFSelection, level: HighlightLevel = .interesting) -> [PDFAnnotation] {
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
            guard var rects = byPage[page] else { continue }
            // touching an existing highlight extends it, keeping its note and level, instead of stacking a second one
            let touched = page.annotations.filter { old in
                (old.type ?? "").replacingOccurrences(of: "/", with: "") == "Highlight"
                    && Marginalia.lineRects(old).contains { o in rects.contains { $0.intersects(o) } }
            }
            for old in touched { rects += Marginalia.lineRects(old) }
            rects = BookMarks.mergeLines(rects)
            guard let first = rects.first else { continue }
            let box = rects.dropFirst().reduce(first) { $0.union($1) }
            let ann = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
            ann.color = touched.compactMap { HighlightLevel.of($0) }.first?.nsColor ?? level.nsColor
            let kept = touched.map { BookMarks.splitContents($0.contents ?? "").note }.filter { !$0.isEmpty }
            if !kept.isEmpty { ann.contents = kept.joined(separator: "\n") }
            ann.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - box.minX, x1 = r.maxX - box.minX
                let y0 = r.minY - box.minY, y1 = r.maxY - box.minY
                return [NSValue(point: NSPoint(x: x0, y: y1)), NSValue(point: NSPoint(x: x1, y: y1)),
                        NSValue(point: NSPoint(x: x0, y: y0)), NSValue(point: NSPoint(x: x1, y: y0))]
            }
            ann.userName = NSFullUserName()
            ann.modificationDate = Date()
            swapHighlights(on: page, remove: touched, add: [ann], name: "Highlight")
            made.append(ann)
        }
        pdfView.clearSelection()
        markUnsaved()
        refreshNotes()
        return made
    }

    func removeHighlight(_ ann: PDFAnnotation) {
        guard let page = ann.page else { return }
        swapHighlights(on: page, remove: [ann], add: [], name: "Remove Highlight")
    }

    /// Takes highlights off a page and puts others on, and records the reverse, so Undo and Redo work.
    private func swapHighlights(on page: PDFPage, remove: [PDFAnnotation], add: [PDFAnnotation], name: String) {
        remove.forEach { page.removeAnnotation($0) }
        add.forEach { page.addAnnotation($0) }
        pdfView.undoManager?.registerUndo(withTarget: self) { v in
            v.swapHighlights(on: page, remove: add, add: remove, name: name)
        }
        pdfView.undoManager?.setActionName(name)
        markUnsaved()
        refreshNotes()
    }

    /// Edit ▸ Undo / Redo: for the note box you're typing in if there is one, otherwise for highlights.
    func undoLast() {
        if !NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) { pdfView.undoManager?.undo() }
    }
    func redoLast() {
        if !NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) { pdfView.undoManager?.redo() }
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

    /// File ▸ Set Printed Page Number…: fixes the number cited for the page on screen. On an ordinary PDF the
    /// pages after it count up from it; on a photo book only this page changes, and it moves to its place.
    func askPageNumber() {
        guard let doc = pdfView.document, let page = pdfView.currentPage else { return }
        let index = doc.index(for: page)
        let photo = PageLabels.isPhotoPage(page)
        let alert = NSAlert()
        alert.messageText = "Printed page number"
        alert.informativeText = photo ? "The number printed on this page." : "The number printed on this page. The pages after it will count up from it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = PageLabels.label(of: page, index: index)
        alert.accessoryView = field
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let label = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return }
        if photo {
            PageLabels.set(label, on: page, photo: true)
            if let rank = BookPages.rank(label) {
                doc.removePage(at: index)
                let ranks = (0..<doc.pageCount).map { i in doc.page(at: i).flatMap(PageLabels.marked).flatMap(BookPages.rank) }
                doc.insert(page, at: BookPages.insertionIndex(rank: rank, among: ranks))
                BookPhotos.keepSummaryOnFirstPage(doc)
                pdfView.go(to: page)
            }
        } else {
            for i in index..<doc.pageCount {
                guard let p = doc.page(at: i), let l = i == index ? label : BookPages.counted(label, by: i - index) else { continue }
                PageLabels.set(l, on: p, photo: false)
            }
        }
        markUnsaved(after: 0.1)
        refreshNotes()
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

    func show(path: String, terms: [String], page: Int, wholeWords: Bool = true, note: NoteTarget? = nil) {
        pdfView.undoManager?.removeAllActions(withTarget: self)     // a load makes fresh pages; old undo steps no longer apply
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
                self.spotlightNoteID = nil
                self.hasSelection = false
                self.refreshNotes()
                self.summary = doc.map(Marginalia.summary) ?? ""
                self.docGen += 1
                if let t = note, let doc = doc, !t.isSummary,
                   let m = self.notes.first(where: { $0.pageIndex == t.page && $0.quote == t.quote && $0.comment == t.comment })
                        ?? self.notes.first(where: { $0.pageIndex == t.page && ($0.quote == t.quote || $0.comment == t.comment) })
                        ?? self.notes.first(where: { $0.pageIndex == t.page }) {
                    // a My Notes result: go to that highlight and outline its card
                    if let k = sels.firstIndex(where: { s in s.pages.first.map { doc.index(for: $0) } == t.page }) {
                        self.matchIndex = k
                    }
                    self.reveal(m)
                    DispatchQueue.main.async { self.spotlightNoteID = m.id }
                } else if note?.isSummary == true, let doc = doc {
                    if let p = doc.page(at: 0) { self.pdfView.go(to: p) }
                } else if !sels.isEmpty {
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
        spotlightNoteID = nil
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

/// The Obsidian vaults on this Mac, from Obsidian's own list (~/Library/Application Support/obsidian/obsidian.json).
enum ObsidianVaults {
    struct Vault: Identifiable, Hashable {
        let path: String
        let opened: Double
        var name: String { (path as NSString).lastPathComponent }
        var id: String { path }
    }
    static func list() -> [Vault] {
        let file = NSHomeDirectory() + "/Library/Application Support/obsidian/obsidian.json"
        guard let data = FileManager.default.contents(atPath: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: Any] else { return [] }
        var out: [Vault] = []
        for case let v as [String: Any] in vaults.values {
            guard let p = v["path"] as? String else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            out.append(Vault(path: p, opened: (v["ts"] as? Double) ?? 0))
        }
        return out.sorted { $0.opened > $1.opened }   // most recently opened first
    }
}

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
    /// "Library/x.pdf" for files inside the Papers folder (so library.bib and notes work wherever
    /// that folder lives: home folder, USB stick, another Mac); anything else stays a full path.
    static func relative(_ path: String) -> String {
        let root = papers.hasSuffix("/") ? papers : papers + "/"
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
    }
    /// the reverse: a path from library.bib or a note link → a full path on this Mac
    static func absolute(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        if path.hasPrefix("~") { return (path as NSString).expandingTildeInPath }
        return papers + "/" + path
    }
    /// write a Markdown note (@key.md) for each annotated paper
    static var writeNotes: Bool { UserDefaults.standard.object(forKey: "writeNotes") as? Bool ?? true }
}

enum CiteStyle { case pandoc, obsidianLink, latex, key }

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
    /// set for a single note (Search in ▸ My Notes)
    var note: NoteInfo? = nil
    /// a normal search that also matched your notes on this paper: the best one, and how many
    var noteSnippet: AttributedString? = nil
    var noteCount = 0
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

/// One of your notes as a search result.
struct NoteInfo {
    let kind: String            // "e" Essential / "h" other highlight or note in the PDF, "s" About this paper, "o" your writing in the paper's Markdown note
    let quote: AttributedString?
    let comment: AttributedString?
    let quoteText: String
    let commentText: String
    let pageIndex: Int          // 0-based
    let pageLabel: String
    let notePath: String?       // the .md file, for "o"
}

/// Which note to point at when a PDF opens from a My Notes result.
struct NoteTarget {
    let page: Int               // 0-based
    let quote: String
    let comment: String
    let isSummary: Bool
}

/// A note as stored in the search index (see DB.store).
struct IndexedNote {
    let kind: String            // "e" Essential highlight, "h" other highlight or note, "s" summary
    let page: Int
    let label: String
    let quote: String
    let comment: String
}

/// Your own writing in a paper note (@key.md): everything below the automatic section.
enum OwnNotes {
    /// pdf: the `pdf:` line of the frontmatter (relative to Papers, as written); key: `citekey:` or the file name
    static func parse(_ text: String, fileName: String) -> (pdf: String, key: String, paragraphs: [String]) {
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")
        var pdf = "", key = ""
        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            let front = body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound]
            for line in front.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let name = parts[0].trimmingCharacters(in: .whitespaces)
                var v = parts[1].trimmingCharacters(in: .whitespaces)
                if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") {
                    v = String(v.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                if name == "pdf" { pdf = v } else if name == "citekey" { key = v }
            }
            // skip the rest of the closing --- line
            let after = body[end.upperBound...]
            body = String(after.drop(while: { $0 != "\n" }))
        }
        if key.isEmpty {
            var k = fileName
            if k.lowercased().hasSuffix(".md") { k = String(k.dropLast(3)) }
            if k.hasPrefix("@") { k = String(k.dropFirst()) }
            key = k
        }
        // a note PDF Search wrote: only what comes after its automatic section is yours
        if let s = body.range(of: Marginalia.startMarker),
           let e = body.range(of: Marginalia.endMarker, range: s.upperBound..<body.endIndex) {
            body = String(body[e.upperBound...])
        }
        var paragraphs: [String] = []
        var cur: [Substring] = []
        func flush() {
            let p = cur.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            cur = []
            guard !p.isEmpty else { return }
            // a heading on its own ("## Notes", "# Title") isn't a note
            if !p.contains("\n") && p.hasPrefix("#") { return }
            paragraphs.append(p)
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { cur.append(line) }
        }
        flush()
        return (pdf, key, paragraphs)
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

final class Library: ObservableObject {
    static let shared = Library()
    /// the "Search in ▸ My Notes" choice (not a folder path)
    static let myNotesScope = "\u{1}mynotes"
    /// the "Search in ▸ Recently Edited" choice: papers you've highlighted or written notes in, newest first
    static let recentScope = "\u{1}recent"
    static let addedScope = "\u{1}added"

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
    /// bumped by View ▸ Zoom to Fit (⌘0) and File ▸ Open Paper Note (⌥⌘O)
    @Published var zoomRequest = 0
    @Published var openNoteRequest = 0
    /// bumped by Help ▸ PDF Search README
    @Published var readmeRequest = 0
    /// a pdfsearch://open?file=…&page=… link to show (from an Obsidian note)
    @Published private(set) var linkRequest: LinkRequest?
    private var lastLinkTime = Date.distantPast
    /// everything in library.bib and any reference .bib files (e.g. a conference archive's)
    @Published private(set) var bib = BibIndex()
    /// the "Add to Library" card being shown (nil file = a book or chapter without a PDF)
    @Published var addRequest: AddRequest?
    private var addQueue: [URL?] = []
    /// the batch of book photos being worked through (a new batch waits for it)
    private var photoTask: Task<Void, Never>?
    /// photos already being worked on, so none is read twice
    private var photoQueued = Set<String>()
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
            self?.checkPhotoInbox()
            self?.syncOwnNotesSoon()   // what you wrote in your paper notes since
        }
        // new photos are picked up on their own while the app is open
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkPhotoInbox() }
    }

    private func noDetailsAlert() {
        let alert = NSAlert()
        alert.messageText = "No citation details for this PDF yet"
        alert.informativeText = "PDF Search only knows the details of items in your library.bib (and reference .bib files inside your Papers folders). Add an entry for it to library.bib, and name the PDF after its key."
        alert.runModal()
    }

    // MARK: bibliography

    /// Re-read library.bib plus any .bib file in an added folder or the folders directly inside it.
    func reloadBib(force: Bool = false) {
        let roots = Array(Set(folders.filter { $0.isRoot }.map(\.path) + [Paths.papers]))
        let libPath = Paths.libraryBib
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
        case .obsidianLink:
            // make sure the note exists, so the link isn't a dead end (and isn't created in the wrong folder)
            text = "[[@\(e.key)]]"
            if let p = path { ensurePaperNote(pdf: p) } else { ensurePaperNote(entry: e) }
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
        let now = Date().timeIntervalSince1970
        writeQ.async {
            self.writer.markEdited(path, at: now)              // for Recently Edited (also counts removals)
            self.index([URL(fileURLWithPath: path)])           // so new notes are searchable
        }
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
                let path = Paths.absolute(file)
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

    func showFlash(_ message: String, seconds: Double = 3) {
        flashGen += 1
        let g = flashGen
        flash = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if g == self.flashGen { self.flash = nil } }
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
        if panel.runModal() == .OK { handleDropped(panel.urls) }
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

    /// Dropped onto the window: photos become book pages; folders become searchable; PDFs already in the
    /// bibliography are just indexed; new PDFs get the Add card (or, for many at once, the choice of just
    /// searching them).
    func handleDropped(_ urls: [URL]) {
        var folders: [URL] = [], known: [URL] = [], new: [URL] = [], photos: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                // a folder of photos and no PDFs is a batch of book pages
                let inside = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                let images = inside.filter(Library.isPhoto)
                if !images.isEmpty, Library.findPDFs(in: u).isEmpty { photos += images } else { folders.append(u) }
            }
            else if Library.isPhoto(u) { photos.append(u) }
            else if u.pathExtension.lowercased() == "pdf" {
                if bib.entry(forPath: u.standardizedFileURL.path) != nil { known.append(u) } else { new.append(u) }
            }
        }
        if !folders.isEmpty || !known.isEmpty { add(folders + known) }
        if !photos.isEmpty { addPhotos(photos) }
        // everything imported gets its details: a folder stays where it is, and its PDFs are looked up in the background
        let inFolders = folders.flatMap { Library.findPDFs(in: $0) }
        if !inFolders.isEmpty { lookUpDetails(inFolders, inPlace: true) }
        guard !new.isEmpty else { return }
        if new.count > 3 {
            add(new)        // searchable straight away; filed in Papers/Library as their details are found
            lookUpDetails(new, inPlace: false)
        } else {
            requestAdd(new)
        }
    }

    /// Save a confirmed entry: move/copy the PDF to Library/<key>.pdf and append to library.bib.
    @discardableResult
    func addToLibrary(type: String, key: String, fields: [String: String], file: URL?, move: Bool,
                      inPlace: Bool = false, quiet: Bool = false) -> Bool {
        let fm = FileManager.default
        var dest: String?
        if inPlace, let src = file?.standardizedFileURL {
            dest = src.path
        } else if let src = file?.standardizedFileURL {
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
        if quiet { return true }      // a batch reloads and rescans once, at the end
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
            if self.syncOwnNotes() { DispatchQueue.main.async { self.runSearchNow() } }
        }
    }

    func syncOwnNotesSoon() {
        writeQ.async { if self.syncOwnNotes() { DispatchQueue.main.async { self.runSearchNow() } } }
    }

    /// Runs on writeQ. Makes what you write in the paper notes (@key.md, below the automatic section)
    /// searchable. Only files changed since last time are read. Returns true if anything changed.
    private func syncOwnNotes() -> Bool {
        let dir = Paths.notesFolder
        let fm = FileManager.default
        var isDir: ObjCBool = false
        // folder missing (e.g. the USB stick isn't plugged in): leave things as they are
        guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return false }
        var current: [String: Double] = [:]
        for f in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where f.lowercased().hasSuffix(".md") && !f.hasPrefix(".") {
            let p = dir + "/" + f
            current[p] = ((try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
        let known = writer.noteFiles()
        var changed = false
        for (p, k) in known where current[p] == nil {
            writer.removeNoteFile(id: k.id)
            changed = true
        }
        for (p, m) in current {
            if let k = known[p], abs(k.mtime - m) < 0.001 { continue }
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else { continue }
            let own = OwnNotes.parse(text, fileName: (p as NSString).lastPathComponent)
            // a rewrite of the automatic section alone changes nothing searchable
            let before = known[p].map { writer.ownParagraphs(noteFileID: $0.id) }
            writer.storeNoteFile(path: p, mtime: m, pdf: own.pdf, key: own.key, paragraphs: own.paragraphs)
            if before != own.paragraphs { changed = true }
        }
        return changed
    }

    /// The paper's Markdown note (@key.md), if there is one.
    func paperNotePath(forPDF path: String) -> String? {
        let p = Marginalia.notePath(pdfPath: path, entry: bib.entry(forPath: path))
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    func paperNotePath(for hit: Hit) -> String? {
        if let p = hit.note?.notePath { return p }
        if !hit.path.isEmpty { return paperNotePath(forPDF: hit.path) }
        if let e = hit.entry {
            let p = Marginalia.folder + "/" + Marginalia.noteFileName(key: e.key)
            return FileManager.default.fileExists(atPath: p) ? p : nil
        }
        return nil
    }

    /// Open the paper's Markdown note (in Obsidian when the notes folder is in a vault), creating it first
    /// if there isn't one yet, so there's somewhere to write before you've highlighted anything.
    func openPaperNote(pdf path: String) {
        if let note = ensurePaperNote(pdf: path) { Marginalia.openNote(note) }
    }

    func openPaperNote(entry: BibEntry) {
        if let note = ensurePaperNote(entry: entry) { Marginalia.openNote(note) }
    }

    /// The paper's note, created first if needed. nil if notes are turned off or it couldn't be written.
    @discardableResult
    func ensurePaperNote(pdf path: String) -> String? {
        var entry = bib.entry(forPath: path)
        if let e = entry, !e.inLibrary { entry = ensureInLibrary(e)?.entry ?? e }
        let note = Marginalia.notePath(pdfPath: path, entry: entry)
        if !FileManager.default.fileExists(atPath: note) {
            guard Paths.writeNotes else { showFlash("Paper notes are turned off in Settings (⌘,)"); return nil }
            let doc = PDFDocument(url: URL(fileURLWithPath: path))
            Marginalia.mirror(pdfPath: path, entry: entry, notes: doc.map(Marginalia.collect) ?? [],
                              summary: doc.map(Marginalia.summary) ?? "", create: true)
        }
        return FileManager.default.fileExists(atPath: note) ? note : nil
    }

    /// The same for a book or other entry without a PDF.
    @discardableResult
    func ensurePaperNote(entry e0: BibEntry) -> String? {
        var e = e0
        if !e.inLibrary { e = ensureInLibrary(e)?.entry ?? e }
        let note = Marginalia.folder + "/" + Marginalia.noteFileName(key: e.key)
        if !FileManager.default.fileExists(atPath: note) {
            guard Paths.writeNotes else { showFlash("Paper notes are turned off in Settings (⌘,)"); return nil }
            var t = "---\ncitekey: \(e.key)\ntitle: \(Marginalia.yaml(e.title))\n"
            if !e.people.isEmpty { t += "authors: \(Marginalia.yaml(e.people.joined(separator: "; ")))\n" }
            if !e.year.isEmpty { t += "year: \(e.year)\n" }
            t += "---\n\n# \(e.title.isEmpty ? e.key : e.title)\n\n\(e.shortCite) · `[@\(e.key)]`\n\n## Notes\n\n"
            do {
                try FileManager.default.createDirectory(atPath: Marginalia.folder, withIntermediateDirectories: true)
                try t.write(toFile: note, atomically: true, encoding: .utf8)
            } catch {
                showFlash("Couldn't write the note: \(error.localizedDescription)"); return nil
            }
        }
        return note
    }

    func openPaperNote(for hit: Hit) {
        if let p = hit.note?.notePath { Marginalia.openNote(p) }
        else if !hit.path.isEmpty { openPaperNote(pdf: hit.path) }
        else if let e = hit.entry { openPaperNote(entry: e) }
    }

    /// Use an Obsidian vault: paper notes in <vault>/Literature, library.bib in the vault. An existing
    /// library.bib elsewhere is copied in (the original is left where it was).
    func useVault(_ vault: String) {
        let d = UserDefaults.standard, fm = FileManager.default
        d.set(vault + "/Literature", forKey: "notesFolder")
        let current = Paths.libraryBib, target = vault + "/library.bib"
        if current != target {
            if !fm.fileExists(atPath: current) || fm.fileExists(atPath: target) {
                d.set(target, forKey: "libraryBib")
            } else if (try? fm.copyItem(atPath: current, toPath: target)) != nil {
                d.set(target, forKey: "libraryBib")
                showFlash("Copied library.bib into your vault")
            }
        }
        d.set(true, forKey: "askedVault")
        reloadBib(force: true)
        syncOwnNotesSoon()
        runSearchNow()
    }

    /// First launch: if you use Obsidian but your vault isn't ~/Obsidian Vault, offer to use it (once).
    func offerVaultIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "askedVault"), Paths.setting("notesFolder") == nil, Paths.vault == nil else { return }
        let vaults = ObsidianVaults.list()
        guard !vaults.isEmpty else { return }
        d.set(true, forKey: "askedVault")
        let alert = NSAlert()
        alert.messageText = vaults.count == 1 ? "Use your Obsidian vault “\(vaults[0].name)”?" : "Use one of your Obsidian vaults?"
        alert.informativeText = "PDF Search keeps a Markdown note for every paper you annotate (your highlights, notes and page links). In your vault they go in a Literature folder, and library.bib goes in the vault too.\n\nYou can change this any time in Settings (⌘,)."
        var picker: NSPopUpButton?
        if vaults.count > 1 {
            let p = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26), pullsDown: false)
            p.addItems(withTitles: vaults.map { $0.name + "  (" + $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") + ")" })
            alert.accessoryView = p
            picker = p
        }
        alert.addButton(withTitle: vaults.count == 1 ? "Use “\(vaults[0].name)”" : "Use This Vault")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        useVault(vaults[picker?.indexOfSelectedItem ?? 0].path)
    }

    /// Every note tagged #tag (a tag chip on a note card).
    func showTag(_ tag: String) {
        scope = Library.myNotesScope
        query = "#" + tag
    }

    /// “quote” [@key, p. 12], ready to paste into a draft.
    func copyQuote(_ quote: String, pageLabel: String, entry: BibEntry?, path: String?) {
        var e = entry ?? path.flatMap { bib.entry(forPath: $0) }
        if let x = e, !x.inLibrary { e = ensureInLibrary(x)?.entry ?? x }
        let cite = e.map { pageLabel.isEmpty ? " [@\($0.key)]" : " [@\($0.key), p. \(pageLabel)]" } ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("“\(quote)”" + cite, forType: .string)
        showFlash(e == nil ? "Copied the quote (this paper has no citation details yet)" : "Copied the quote with [@\(e!.key)]")
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
                let ex = autoreleasepool { Library.extract(URL(fileURLWithPath: item.path)) }
                lock.lock()
                self.writer.store(path: item.path, mtime: item.mtime, size: item.size, pages: ex?.pages, notes: ex?.notes ?? [],
                                  edited: ex?.edited)
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
            if let s = self.scope, s != Library.myNotesScope, s != Library.recentScope, s != Library.addedScope, !f.contains(where: { $0.path == s }) { self.scope = nil }
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

    /// Text of every page, plus your highlights and notes (for My Notes), or nil if the PDF can't be opened.
    static func extract(_ url: URL) -> (pages: [String], notes: [IndexedNote], edited: Double?)? {
        guard let doc = PDFDocument(url: url), !doc.isLocked else { return nil }
        var pages: [String] = []
        pages.reserveCapacity(doc.pageCount)
        var annotated = false
        var edited: Double?      // newest highlight/note date (set by PDF Search when you change one)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { pages.append(""); continue }
            var text = page.string ?? ""
            // your margin notes are part of the page, so searching finds them
            let marks = page.annotations.filter(Marginalia.isMarkup)
            if !marks.isEmpty { annotated = true }
            for m in marks {
                if let d = m.modificationDate?.timeIntervalSince1970, d > (edited ?? 0), d < Date().timeIntervalSince1970 + 86_400 { edited = d }
            }
            let notes = marks.compactMap { $0.contents }.filter { !$0.isEmpty }
            if !notes.isEmpty { text += "\n" + notes.joined(separator: "\n") }
            pages.append(text)
        }
        var notes: [IndexedNote] = []
        if annotated {
            let s = Marginalia.summary(doc)
            if !s.isEmpty { notes.append(IndexedNote(kind: "s", page: 0, label: "", quote: "", comment: s)) }
            for n in Marginalia.collect(doc) where !(n.quote.isEmpty && n.comment.isEmpty) {
                notes.append(IndexedNote(kind: n.level == .essential ? "e" : "h", page: n.pageIndex, label: n.pageLabel,
                                         quote: n.quote, comment: n.comment))
            }
        }
        return (pages, notes, edited)
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
        let myNotes = self.scope == Library.myNotesScope
        let added = self.scope == Library.addedScope
        let recent = self.scope == Library.recentScope || added
        let scope = (!myNotes && !recent) ? self.scope : nil
        let bib = self.bib
        let indexed = self.indexedPaths
        readQ.async {
            let (fts, terms, parts) = Library.parse(q)
            let empty = q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if recent {
                // papers you've worked on (or added), newest first; typing searches just those
                let rec = added ? self.reader.addedFiles() : self.reader.recentFiles()
                var hits: [Hit]
                if empty {
                    hits = rec.map { Hit(id: $0.id, path: $0.path, page: 0, badge: Library.when($0.time), snippet: nil) }
                } else if fts.isEmpty {
                    hits = []
                } else {
                    let times = Dictionary(rec.map { ($0.id, $0.time) }, uniquingKeysWith: { a, b in max(a, b) })
                    hits = self.reader.search(all: parts, scope: nil)
                        .compactMap { h -> Hit? in
                            guard let t = times[h.id] else { return nil }
                            return Hit(id: h.id, path: h.path, page: h.page, badge: Library.when(t), snippet: h.snippet)
                        }
                        .sorted { (times[$0.id] ?? 0) > (times[$1.id] ?? 0) }
                }
                for i in hits.indices { hits[i].entry = bib.entry(forPath: hits[i].path) }
                DispatchQueue.main.async {
                    guard g == self.searchGen else { return }
                    self.results = hits
                    self.scopedCount = hits.count
                    if self.terms != terms { self.terms = terms }
                }
                return
            }
            if myNotes {
                let hits = empty ? self.notedPapers(bib: bib, indexed: indexed)
                                 : (fts.isEmpty ? [] : self.noteHits(fts, tags: Marginalia.tags(in: q), bib: bib, indexed: indexed))
                DispatchQueue.main.async {
                    guard g == self.searchGen else { return }
                    self.results = hits
                    self.scopedCount = hits.count
                    if self.terms != terms { self.terms = terms }
                }
                return
            }
            var hits: [Hit]
            if empty {
                hits = self.reader.allFiles(scope: scope)
            } else if fts.isEmpty {
                hits = []
            } else {
                hits = self.reader.search(all: parts, scope: scope)
                self.attachNotes(&hits, fts: fts, scope: scope, bib: bib, indexed: indexed)
            }
            for i in hits.indices where hits[i].entry == nil { hits[i].entry = bib.entry(forPath: hits[i].path) }
            // library entries without an indexed PDF (books etc.) belong to the Library folder
            let lib = Paths.libraryFolder
            if scope == nil || scope == lib || lib.hasPrefix(scope! + "/") {
                let folded = terms.map(BibIndex.fold).filter { !$0.isEmpty }
                let listed = Set(hits.compactMap { $0.path.isEmpty ? $0.entry?.key : nil })
                for (i, e) in bib.entries.enumerated() where e.inLibrary {
                    if listed.contains(e.key) { continue }
                    if let f = e.file, indexed.contains(BibIndex.norm(f)) { continue }
                    if indexed.contains(BibIndex.norm(lib + "/" + e.key + ".pdf")) { continue }
                    if !empty && !Library.entryMatches(bib.searchBlobs[i], folded) { continue }
                    hits.append(Hit(id: -(i + 1), path: "", page: 0, badge: e.kindLabel + " · no PDF", snippet: nil, entry: e))
                }
            }
            if empty {
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

    /// Separate words must all be in the PDF, anywhere in it, in any order; the last letters of a word may be
    /// missing ("access" finds "accessible"). "Quoted text" is an exact phrase. Capitals and accents are ignored.
    /// Commas and semicolons separate words like spaces do. A #tag is a term of its own.
    /// `fts` asks for every term in one row, which is how notes are matched; `parts` is each term alone.
    static func parse(_ q: String) -> (fts: String, terms: [String], parts: [String]) {
        var parts: [String] = []
        var terms: [String] = []
        let ns = q as NSString
        let re = try! NSRegularExpression(pattern: "\"([^\"]*)\"")
        let full = NSRange(location: 0, length: ns.length)
        for m in re.matches(in: q, range: full) {
            let phrase = ns.substring(with: m.range(at: 1))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if hasWordChars(phrase) { parts.append("\"\(phrase)\""); terms.append(phrase) }
        }
        let rest = re.stringByReplacingMatches(in: q, range: full, withTemplate: " ")
            .replacingOccurrences(of: "\"", with: " ")
        for w in rest.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" }) {
            let word = String(w)
            guard hasWordChars(word) else { continue }
            if word.hasPrefix("#") {
                // a #tag is its own term (My Notes keeps only notes really tagged with it)
                let tag = String(word.drop(while: { $0 == "#" }))
                if hasWordChars(tag) { parts.append("\"\(tag)\""); terms.append(tag) }
            } else {
                parts.append("\"\(word)\"*")      // FTS5: * means the word may go on
                terms.append(word)
            }
        }
        return (parts.joined(separator: " "), terms, parts)
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

    /// "today 2:14 pm", "yesterday", "Tuesday", "Oct 28", "Oct 28, 2025"
    static func when(_ t: Double) -> String {
        let d = Date(timeIntervalSince1970: t)
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale.current
        if cal.isDateInToday(d) {
            f.dateFormat = "h:mm a"
            return "today " + f.string(from: d).lowercased()
        }
        if cal.isDateInYesterday(d) { return "yesterday" }
        if let days = cal.dateComponents([.day], from: d, to: Date()).day, days < 6 {
            f.dateFormat = "EEEE"
            return f.string(from: d)
        }
        f.dateFormat = cal.isDate(d, equalTo: Date(), toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: d)
    }

    // MARK: My Notes (runs on readQ)

    /// The PDF and bibliography entry a note belongs to. Notes in a PDF know their file; a paper
    /// note (.md) says which PDF in its frontmatter, or is found by its key.
    private func resolve(_ r: NoteRow, bib: BibIndex, indexed: Set<String>) -> (path: String, entry: BibEntry?) {
        if r.kind != "o" { return (r.filePath, bib.entry(forPath: r.filePath)) }
        var path = r.pdf.isEmpty ? "" : Paths.absolute(r.pdf)
        let byKey = bib.libraryByStem[r.key]
        if path.isEmpty, let f = byKey?.file { path = f }
        if !path.isEmpty && !indexed.contains(BibIndex.norm(path)) && !FileManager.default.fileExists(atPath: path) { path = "" }
        return (path, path.isEmpty ? byKey : (bib.entry(forPath: path) ?? byKey))
    }

    private static func info(_ r: NoteRow) -> NoteInfo {
        NoteInfo(kind: r.kind,
                 quote: r.quote.isEmpty ? nil : DB.highlight(r.quoteHL),
                 comment: r.comment.isEmpty ? nil : DB.highlight(r.commentHL),
                 quoteText: r.quote, commentText: r.comment,
                 pageIndex: r.page, pageLabel: r.label.isEmpty ? String(r.page + 1) : r.label,
                 notePath: r.kind == "o" ? r.notePath : nil)
    }

    /// One line for a normal search result: the note that matched.
    private static func snippetLine(_ r: NoteRow) -> AttributedString {
        let label: String, body: String
        switch r.kind {
        case "s": label = "About this paper: "; body = r.commentHL
        case "o": label = "Your paper note: "; body = r.commentHL
        default:
            let star = r.kind == "e" ? "★ Essential · " : ""
            if r.quote.isEmpty || r.commentHL.contains("\u{2}") { label = star + "Your note: "; body = r.commentHL }
            else { label = star.isEmpty ? "You highlighted: " : star; body = "“" + r.quoteHL + "”" }
        }
        var a = AttributedString(label)
        a.font = Font.callout.weight(.semibold)
        a += DB.highlight(body)
        return a
    }

    /// Search in ▸ My Notes, with words typed: one result per note.
    private func noteHits(_ fts: String, tags: [String] = [], bib: BibIndex, indexed: Set<String>) -> [Hit] {
        // Essential passages first, otherwise best match first; "#tag" in the query keeps only notes tagged with it
        let rows = reader.searchNotes(fts)
            .filter { r in tags.allSatisfy { Marginalia.hasTag(r.comment + "\n" + r.quote, $0) } }
            .enumerated()
            .sorted { a, b in (a.element.kind == "e") != (b.element.kind == "e") ? a.element.kind == "e" : a.offset < b.offset }
            .map { $0.element }
        return rows.compactMap { (r: NoteRow) -> Hit? in
            let (path, entry) = resolve(r, bib: bib, indexed: indexed)
            if path.isEmpty && entry == nil { return nil }
            let badge: String
            switch r.kind {
            case "s": badge = "about this paper"
            case "o": badge = "paper note"
            default: badge = (r.kind == "e" ? "★ " : "") + "p. " + (r.label.isEmpty ? String(r.page + 1) : r.label)
            }
            var h = Hit(id: r.rowid, path: path, page: r.kind == "o" ? 0 : r.page + 1, badge: badge, snippet: nil, entry: entry)
            h.note = Library.info(r)
            return h
        }
    }

    /// Search in ▸ My Notes, nothing typed: every paper you've written notes on.
    private func notedPapers(bib: BibIndex, indexed: Set<String>) -> [Hit] {
        var papers: [String: Hit] = [:]
        var counts: [String: Int] = [:]
        for f in reader.notedFiles() {
            let k = BibIndex.norm(f.path)
            papers[k] = Hit(id: f.id, path: f.path, page: 0, badge: "", snippet: nil, entry: bib.entry(forPath: f.path))
            counts[k] = f.count
        }
        for f in reader.ownNoteFiles() {
            let row = NoteRow(rowid: 0, filePath: "", notePath: f.path, pdf: f.pdf, key: f.key, kind: "o", page: 0, label: "",
                              quote: "", comment: "", quoteHL: "", commentHL: "", score: 0)
            let (path, entry) = resolve(row, bib: bib, indexed: indexed)
            if path.isEmpty && entry == nil { continue }
            let k = path.isEmpty ? "key:" + (entry?.key ?? f.key) : BibIndex.norm(path)
            if papers[k] == nil {
                papers[k] = Hit(id: -(f.id * NOTE_SLOTS), path: path, page: 0, badge: "", snippet: nil, entry: entry)
            }
            counts[k, default: 0] += f.count
        }
        return papers.map { (pair: (key: String, value: Hit)) -> Hit in
            let n = counts[pair.key] ?? 0
            let h = pair.value
            return Hit(id: h.id, path: h.path, page: 0, badge: n == 1 ? "1 note" : "\(n) notes", snippet: nil, entry: h.entry)
        }.sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }

    /// A normal search: show under each result the note of yours that matched, and add papers
    /// that only matched in your paper notes.
    private func attachNotes(_ hits: inout [Hit], fts: String, scope: String?, bib: BibIndex, indexed: Set<String>) {
        let rows = reader.searchNotes(fts)
        guard !rows.isEmpty else { return }
        var groups: [String: [NoteRow]] = [:]
        var where_: [String: (path: String, entry: BibEntry?)] = [:]
        var order: [String] = []
        for r in rows {
            let (path, entry) = resolve(r, bib: bib, indexed: indexed)
            if path.isEmpty {
                guard scope == nil, let e = entry else { continue }
                let k = "key:" + e.key
                if groups[k] == nil { order.append(k); where_[k] = (path, entry) }
                groups[k, default: []].append(r)
            } else {
                if let s = scope, !path.hasPrefix(s + "/") { continue }
                let k = BibIndex.norm(path)
                if groups[k] == nil { order.append(k); where_[k] = (path, entry) }
                groups[k, default: []].append(r)
            }
        }
        var at: [String: Int] = [:]
        for (i, h) in hits.enumerated() where !h.path.isEmpty { at[BibIndex.norm(h.path)] = i }
        for k in order {
            guard let rs = groups[k], let w = where_[k], let first = rs.first(where: { $0.kind == "e" }) ?? rs.first else { continue }
            if let i = at[k] {
                hits[i].noteSnippet = Library.snippetLine(first)
                hits[i].noteCount = rs.count
            } else {
                let id = first.kind == "o" ? first.rowid : first.rowid / NOTE_SLOTS
                var h = Hit(id: id, path: w.path, page: first.kind == "o" ? 0 : first.page + 1,
                            badge: "in your notes", snippet: nil, entry: w.entry)
                h.noteSnippet = Library.snippetLine(first)
                h.noteCount = rs.count
                hits.append(h)
            }
        }
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
    /// Organisations written in double braces in the .bib (`{{National Science Foundation}}`): shown whole,
    /// never cut down to a "surname".
    var organisations: Set<String> {
        let r = raw["author"] ?? raw["editor"] ?? ""
        var out: Set<String> = []
        for part in r.components(separatedBy: " and ") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix("{") && p.hasSuffix("}") { out.insert(BibParser.decodeLaTeX(p)) }
        }
        return out
    }
    /// "Cascone (2000)", "Fasciani & Goode (2021)", "Smith et al. (2019)", "National Science Foundation (2022)"
    var shortCite: String {
        let orgs = organisations
        let names = people.map { orgs.contains($0) ? $0 : BibEntry.lastName($0) }
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

    /// Accepts "Library/x.pdf" (relative to the Papers folder), "/path/x.pdf", "~/x.pdf",
    /// or JabRef/Zotero style ":/path/x.pdf:PDF;…".
    static func filePath(_ value: String?) -> String? {
        guard let v = value, !v.isEmpty else { return nil }
        for part in v.components(separatedBy: ";") {
            var p = part.trimmingCharacters(in: .whitespaces)
            if let r = p.range(of: ".pdf", options: [.caseInsensitive, .backwards]) { p = String(p[..<r.upperBound]) }
            if p.hasPrefix(":") || p.contains(":/") || p.contains(":~") {   // "description:path:type"
                if let s = p.firstIndex(where: { $0 == "/" || $0 == "~" }) { p = String(p[s...]) }
            }
            guard p.lowercased().hasSuffix(".pdf") else { continue }
            return URL(fileURLWithPath: Paths.absolute(p)).standardizedFileURL.path
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
        if let f = file { lines.append("  file = {\(Paths.relative(f))}") }
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
        print("SELFTEST ids: doi=\(Lookup.doi(in: "https://doi.org/10.1162/014892600559489.") ?? "-") arxiv=\(Lookup.arxiv(in: "arXiv:2103.01234v2 [cs.SD]") ?? "-") isbn=\(Lookup.isbn(in: "ISBN 978-0-415-99873-4") ?? "-") isbnText=\(Lookup.isbnInText("Printed in UK. ISBN-13: 978-0-415-99873-4 (pbk)") ?? "-") notIsbn=\(Lookup.isbn(in: "The Aesthetics of Failure") ?? "-") name=\(Lookup.lastFirst("Kim Cascone")) kind=\(Lookup.kind("journal-article").rawValue)")
        let inPapers = Paths.papers + "/Library/smith2019glitch.pdf"
        print("SELFTEST relative: \(Paths.relative(inPapers)) | back: \(Paths.absolute(Paths.relative(inPapers)) == inPapers) | outside stays: \(Paths.relative("/tmp/x.pdf")) | bib field: \(BibParser.filePath("Library/smith2019glitch.pdf") == inPapers) | jabref: \(BibParser.filePath(":/Users/x/a b.pdf:PDF") ?? "-")")
        let md = "---\ncitekey: smith2019glitch\ntitle: \"A: \\\"B\\\"\"\npdf: \"Library/smith 2019.pdf\"\n---\n\n# A\n\nheader line\n\n"
            + Marginalia.startMarker + "\n## Marginalia\n\n> “quote” (p. 2)\n\n" + Marginalia.endMarker
            + "\n\n## Notes\n\nFirst thought about\nglitch.\n\n- a list\n- of two\n\n### Heading\n\n"
        let own = OwnNotes.parse(md, fileName: "@smith2019glitch.md")
        print("SELFTEST own notes: pdf=\(own.pdf) key=\(own.key) paragraphs=\(own.paragraphs) (expect 2)")
        let plain = OwnNotes.parse("# My own note\n\nOnly text.\n", fileName: "@jones2020x.md")
        print("SELFTEST own notes (no frontmatter): key=\(plain.key) paragraphs=\(plain.paragraphs)")
        let cols: [(String, NSColor)] = [("ours", HighlightLevel.interesting.nsColor), ("zotero", NSColor(srgbRed: 1, green: 0.831, blue: 0, alpha: 1)),
                                         ("essential", HighlightLevel.essential.nsColor), ("green", NSColor(srgbRed: 0.37, green: 0.7, blue: 0.21, alpha: 1)),
                                         ("orange", NSColor(srgbRed: 1, green: 0.55, blue: 0, alpha: 1)), ("grey", NSColor(srgbRed: 0.6, green: 0.6, blue: 0.6, alpha: 1))]
        print("SELFTEST yellow? " + cols.map { "\($0.0)=\(HighlightLevel.isYellow($0.1))" }.joined(separator: " ") + " (expect true true false false false false)")
        print("SELFTEST thumbnails: isbn=\(Thumbnails.isbn("978-0-262-01234-5; 0262012340") ?? "-") none=\(Thumbnails.isbn("n/a") ?? "-") hash=\(Thumbnails.hash("pdf|/x.pdf|1|2"))")
        // build.sh runs the self-test from the source folder, next to test-pdfs/
        let pdf = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("test-pdfs")
        if let first = (try? FileManager.default.contentsOfDirectory(atPath: pdf.path))?.first(where: { $0.hasSuffix(".pdf") }) {
            let d = Thumbnails.render(pdf.appendingPathComponent(first).path)
            print("SELFTEST thumbnail of \(first): \(d.map { "\($0.count) bytes, " + (NSImage(data: $0).map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "unreadable") } ?? "FAILED")")
        }
        let now = Date().timeIntervalSince1970
        print("SELFTEST recent labels: \(Library.when(now - 60)) | \(Library.when(now - 86_400)) | \(Library.when(now - 3 * 86_400)) | \(Library.when(now - 40 * 86_400)) | \(Library.when(now - 400 * 86_400))")
        print("SELFTEST tags: \(Marginalia.tags(in: "key idea #improvisation and #Ecology/sound, #improvisation again; not C# or page#3 or #1 or &#39;")) (expect [improvisation, Ecology/sound]) | has: \(Marginalia.hasTag("see #Ecology/sound here", "ecology")) \(Marginalia.hasTag("#improvisational", "improvisation")) (expect true false)")
        print("SELFTEST obsidian vaults: \(ObsidianVaults.list().map { $0.name + " " + $0.path })")
        print("SELFTEST phrase search: \(Library.parse("Accessible instrument des").fts) | \(Library.parse("accessible, design").fts) | \(Library.parse("#improvisation listening body").fts) | terms \(Library.parse("accessible instrument design").terms)")
        let orgBib = "@misc{nsf2022advancing,\n  author = {{National Science Foundation}},\n  title = {AISL},\n  year = {2022}\n}\n@book{x,\n  author = {Ito, Mizuko and boyd, danah and {Make Noise}},\n  year = {2010}\n}\n"
        print("SELFTEST organisations: \(BibParser.parse(orgBib, inLibrary: true).map { $0.shortCite }) (expect [National Science Foundation (2022), Ito et al. (2010)])")
        let fts = Library.parse("glitch \"post digital\"").fts
        print("SELFTEST notes query: \(fts) | note file: \(Marginalia.noteFileName(key: "a/b:c"))")
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
        photoBook()
    }

    /// Book pages from photos, end to end, with made-up photos: reading, page numbers, the hidden markers, saving.
    static func photoBook() {
        let r = BookPages.self
        func line(_ t: String, _ y: CGFloat) -> OCRLine { OCRLine(text: t, box: CGRect(x: 0.1, y: y, width: 0.8, height: 0.02), words: []) }
        print("SELFTEST page numbers: \(r.printedNumber([line("143", 0.05)], cropped: true) ?? "-") \(r.printedNumber([line("42 THE BOOK TITLE", 0.95)], cropped: true) ?? "-") \(r.printedNumber([line("CONTRIBUTORS vii", 0.95)], cropped: true) ?? "-") \(r.printedNumber([line("12 Ibid., 46.", 0.05)], cropped: true) ?? "none") \(r.fillGaps(["142", nil, "144"]).map { $0 ?? "?" }) (expect 143 42 vii none [142, 143, 144])")
        print("SELFTEST photo isbn: \(r.isbns(in: "ISBN 978-0-415-99873-4 (pbk)")) bad=\(r.isbns(in: "ISBN 978-0-415-99873-5")) ten=\(r.isbn13("0-415-99873-5") ?? "-") (expect [9780415998734] [] 9780415998734)")
        print("SELFTEST search words: \(Library.parse("Peters Taylor").parts) | \(Library.parse("\"exact phrase\" other").parts) | \(Library.parse("one, two").parts) (expect each word apart, the quoted phrase whole)")
        print("SELFTEST key terms: \(BookMarks.tag(["a", "process", "of", "adoption)"])?.tag ?? "-") \(BookMarks.tag(["of", "the"])?.tag ?? "none") (expect process-of-adoption none)")
        print("SELFTEST title check: \(r.titleAppears("The Aesthetics of Failure", in: "Aesthetics of Failure, by Kim Cascone")) \(r.titleAppears("Protein Folding Models", in: "The aesthetics of failure")) (expect true false)")
        print("SELFTEST head match: \(r.headMatches("THE POETICS OF SPACE", title: "The Poetics of Space: A Study")) \(r.headMatches("Introduction", title: "The Poetics of Space")) (expect true false)")

        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pdfsearch-selftest-" + UUID().uuidString)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // a white page, slightly turned, on a dark table
        func fakePhoto(_ name: String, head: String?, body: [String], number: String?, marks: Bool = false) -> URL? {
            let w = 1800, h = 2400
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.setFillColor(CGColor(red: 0.13, green: 0.12, blue: 0.11, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            c.translateBy(x: 900, y: 1200)
            c.rotate(by: 0.03)
            c.setFillColor(CGColor(red: 1, green: 1, blue: 0.98, alpha: 1))
            let page = CGRect(x: -650, y: -950, width: 1300, height: 1900)
            c.fill(page)
            let font = CTFontCreateWithName("Times New Roman" as CFString, 46, nil)
            func draw(_ s: String, _ x: CGFloat, _ y: CGFloat) {
                let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)]
                c.textPosition = CGPoint(x: x, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs) as CFAttributedString), c)
            }
            if let t = head { draw(t, -420, 860) }
            for (i, t) in body.enumerated() { draw(t, -540, 740 - CGFloat(i) * 72) }
            if let n = number { draw(n, -20, -880) }
            if marks {      // lines 3 to 5: a yellow streak in the margin, and a pen line under each
                c.setFillColor(CGColor(red: 0.97, green: 0.93, blue: 0.2, alpha: 1))
                c.fill(CGRect(x: -620, y: 740 - 4 * 72 - 10, width: 50, height: 3 * 72 + 30))
                c.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                for i in 2...4 { c.fill(CGRect(x: -540, y: 740 - CGFloat(i) * 72 - 14, width: 860, height: 4)) }
            }
            guard let image = c.makeImage() else { return nil }
            let url = dir.appendingPathComponent(name)
            guard let out = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(out, image, nil)
            return CGImageDestinationFinalize(out) ? url : nil
        }
        let words = ["the imaginary is what enables practices", "through making sense of them together", "people imagine their social existence",
                     "how things go on between them and others", "the expectations that are normally met", "and the deeper images underlying these"]
        func page(_ name: String, _ n: String) -> PagePhoto? {
            guard let u = fakePhoto(name, head: "MODERN SOCIAL IMAGINARIES", body: words + words + words, number: n) else { return nil }
            return BookPhotos.read(u, style: .mine).first
        }
        guard let p42 = page("a.jpg", "42"), let p41 = page("b.jpg", "41") else { print("SELFTEST photo book: FAILED to read a photo"); return }
        let found = BookPages.printedNumber(p42.lines, cropped: p42.cropped) ?? "-"
        print("SELFTEST photo read: \(p42.lines.count) lines, \(p42.text.count) characters, cropped=\(p42.cropped), number=\(found), heads=\(BookPages.runningHeads(p42.lines, cropped: p42.cropped)), \(p42.jpeg.count / 1024) KB (expect about 20 lines, cropped=true, number=42, head MODERN SOCIAL IMAGINARIES)")
        if let u = fakePhoto("isbn.jpg", head: nil, body: ["Copyright 2004 Duke University Press", "ISBN 978-0-415-99873-4 (pbk)"], number: nil) {
            print("SELFTEST photo ISBN read: \(BookPhotos.read(u, style: .mine).first?.isbns ?? []) (expect [9780415998734])")
        }
        let book = dir.appendingPathComponent("book.pdf")
        let a = BookPhotos.add([(photo: p42, label: "42")], to: book)
        let b = BookPhotos.add([(photo: p41, label: "41"), (photo: p42, label: "cover")], to: book)
        let c = BookPhotos.add([(photo: p42, label: "42")], to: book)      // a second photo of p. 42 replaces the first
        guard let doc = PDFDocument(url: book) else { print("SELFTEST photo book: FAILED to open the PDF (\(String(describing: a)) \(String(describing: b)) \(String(describing: c)))"); return }
        let labels = (0..<doc.pageCount).compactMap { doc.page(at: $0) }.enumerated().map { PageLabels.label(of: $1, index: $0) }
        print("SELFTEST photo book labels: \(labels) (expect [cover, 41, 42])")
        print("SELFTEST photo book: \(doc.findString("imaginary", withOptions: .caseInsensitive).count) matches for a word in the picture, text=\((doc.page(at: 2)?.string ?? "").prefix(50).replacingOccurrences(of: "\n", with: " / "))…, \((try? fm.attributesOfItem(atPath: book.path))?[.size] as? Int ?? 0) bytes")
        print("SELFTEST photo thumbnail page: \(doc.page(at: 0).map { PageLabels.marked($0) ?? "-" } ?? "-"), photo book=\(BookPhotos.isPhotoBook(book)), cover=\(BookPhotos.hasCover(book)) (expect cover true true)")
        // a highlight on a photo page, through a save: the marker survives and the citation uses the printed number
        if let target = doc.page(at: 2), let sel = doc.findString("imaginary", withOptions: .caseInsensitive).first(where: { $0.pages.first === target }) {
            let box = sel.bounds(for: target)
            let h = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
            h.quadrilateralPoints = [NSPoint(x: 0, y: box.height), NSPoint(x: box.width, y: box.height), NSPoint(x: 0, y: 0), NSPoint(x: box.width, y: 0)].map { NSValue(point: $0) }
            h.contents = "a note"
            target.addAnnotation(h)
            let saved = dir.appendingPathComponent("saved.pdf")
            let ok = doc.write(to: saved)
            if let again = PDFDocument(url: saved) {
                let n = Marginalia.collect(again).first
                let marks = again.page(at: 2)?.annotations.filter(Marginalia.isMarkup).count ?? -1
                let hidden = again.page(at: 2)?.annotations.first(where: PageLabels.isMarker)?.shouldDisplay
                print("SELFTEST photo highlight: saved=\(ok) page=\(n?.pageLabel ?? "-") quote=\(n?.quote ?? "-") markup=\(marks) markerShown=\(hidden.map(String.init(describing:)) ?? "-") (expect true 42 imaginary 1 false)")
            }
        } else { print("SELFTEST photo highlight: FAILED, the word wasn't found on page 42") }
        // a yellow streak beside underlined lines becomes one Interesting highlight
        if let u = fakePhoto("marked.jpg", head: "MODERN SOCIAL IMAGINARIES", body: words + words + words, number: "43", marks: true),
           let marked = BookPhotos.read(u, style: .mine).first {
            let file = dir.appendingPathComponent("marked.pdf")
            _ = BookPhotos.add([(photo: marked, label: "43")], to: file)
            let n = PDFDocument(url: file).map(Marginalia.collect)?.first
            print("SELFTEST photo marks: \(marked.passages.count) passage, \(marked.passages.first?.boxes.count ?? 0) lines, level=\(n?.level?.name ?? "-"), page=\(n?.pageLabel ?? "-"), quote=\((n?.quote ?? "-").prefix(40))…, note=[\(n?.comment ?? "-")] (expect 1 passage, 3 lines, Interesting, 43, people imagine…, empty note)")
            if let doc3 = PDFDocument(url: file), let a = Marginalia.collect(doc3).first?.annotation {
                a.contents = BookMarks.joinContents(note: "my note", quote: "the corrected words")
                let saved = dir.appendingPathComponent("edited.pdf")
                _ = doc3.write(to: saved)
                let e = PDFDocument(url: saved).map(Marginalia.collect)?.first
                print("SELFTEST photo edited quote: quote=\(e?.quote ?? "-") note=\(e?.comment ?? "-") (expect the corrected words, my note)")
            }
        }
        // words narrower or wider than the font's own shape must still come back whole
        let squeezed = OCRLine(text: "pharmakon hypomnemata", box: CGRect(x: 0.1, y: 0.5, width: 0.5, height: 0.03),
                               words: [OCRWord(text: "pharmakon", box: CGRect(x: 0.1, y: 0.5, width: 0.1, height: 0.03)),
                                       OCRWord(text: "hypomnemata", box: CGRect(x: 0.25, y: 0.5, width: 0.4, height: 0.03))])
        let tight = PagePhoto(source: dir, jpeg: p41.jpeg, original: p41.jpeg, lines: [squeezed], cropped: true, isbns: [])
        let tightText = BookPhotos.pageData(tight).flatMap { PDFDocument(data: $0)?.page(at: 0)?.string } ?? ""
        print("SELFTEST photo word spacing: \(tightText.trimmingCharacters(in: .whitespacesAndNewlines)) (expect pharmakon hypomnemata)")
        // the inbox: a photo moved to Done never replaces one already there
        let shot = dir.appendingPathComponent("IMG_1.jpg"), done = dir.appendingPathComponent("Done").path
        fm.createFile(atPath: shot.path, contents: Data("one".utf8))
        let m1 = BookPhotos.move(shot, into: done)
        fm.createFile(atPath: shot.path, contents: Data("two".utf8))
        let m2 = BookPhotos.move(shot, into: done)
        print("SELFTEST photo inbox: moved \(m1) \(m2), Done holds \(((try? fm.contentsOfDirectory(atPath: done)) ?? []).sorted()), left behind=\(fm.fileExists(atPath: shot.path)) (expect true true [IMG_1 2.jpg, IMG_1.jpg] false)")
        print("SELFTEST obsidian link: \(Marginalia.obsidianLink(note: "/Volumes/R/My Vault/Literature/@smith2020a.md", vault: "/Volumes/R/My Vault") ?? "-") (expect vault=My%20Vault&file=Literature%2F%40smith2020a)")
        // the marker on an ordinary PDF (how page numbers get fixed on existing papers)
        if let doc2 = PDFDocument(data: BookPhotos.pageData(p41) ?? Data()), let only = doc2.page(at: 0) {
            PageLabels.set("177", on: only, photo: false)
            PageLabels.set("178", on: only, photo: false)
            let file = dir.appendingPathComponent("plain.pdf")
            _ = doc2.write(to: file)
            let back = PDFDocument(url: file)?.page(at: 0)
            print("SELFTEST page marker: \(back.map { PageLabels.label(of: $0, index: 0) } ?? "-"), markers=\(back?.annotations.filter(PageLabels.isMarker).count ?? -1) (expect 178, 1)")
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
    /// Essential / Interesting for highlights; nil for sticky notes
    var level: HighlightLevel? { HighlightLevel.of(annotation) }
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
    private static let tagPattern = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}_&/#])#([\\p{L}_][\\p{L}\\p{N}_\\-/]*)")

    /// #tags in a note, in order, without repeats (Obsidian's rules: starts with a letter; letters, digits, _ - /)
    static func tags(in text: String) -> [String] {
        let ns = text as NSString
        var seen = Set<String>()
        var out: [String] = []
        for m in tagPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var t = ns.substring(with: m.range(at: 1))
            while t.hasSuffix("/") || t.hasSuffix("-") { t.removeLast() }
            if !t.isEmpty, seen.insert(t.lowercased()).inserted { out.append(t) }
        }
        return out
    }

    /// does this text carry #tag (or a nested #tag/sub)?
    static func hasTag(_ text: String, _ tag: String) -> Bool {
        let esc = NSRegularExpression.escapedPattern(for: tag)
        guard let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}_&/#])#" + esc + "(?![\\p{L}\\p{N}_\\-])",
                                                options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static let startMarker = "<!-- marginalia:start -->"
    static let endMarker = "<!-- marginalia:end -->"

    /// All highlights and notes in a PDF, in reading order.
    static func collect(_ doc: PDFDocument) -> [MarginNote] {
        var out: [MarginNote] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let label = PageLabels.label(of: page, index: i)
            let anns = page.annotations.filter { isMarkup($0) && !isSummary($0) }.sorted { a, b in
                if abs(a.bounds.maxY - b.bounds.maxY) > 3 { return a.bounds.maxY > b.bounds.maxY }
                return a.bounds.minX < b.bounds.minX
            }
            for a in anns {
                out.append(MarginNote(annotation: a, pageIndex: i, pageLabel: label, quote: quote(a, page),
                                      comment: BookMarks.splitContents(a.contents ?? "").note.trimmingCharacters(in: .whitespacesAndNewlines),
                                      color: a.color))
            }
        }
        return out
    }

    /// The text under a highlight, line by line.
    /// A highlight's line boxes in page coordinates.
    static func lineRects(_ a: PDFAnnotation) -> [CGRect] {
        guard let q = a.quadrilateralPoints, q.count >= 4 else { return [a.bounds] }
        var out: [CGRect] = []
        for k in stride(from: 0, to: q.count - 3, by: 4) {
            let pts = q[k..<(k + 4)].map { $0.pointValue }
            let xs = pts.map { $0.x }, ys = pts.map { $0.y }
            if let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() {
                out.append(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0))
            }
        }
        // PDFKit keeps these relative to the annotation; some files use page coordinates
        let shifted = out.map { $0.offsetBy(dx: a.bounds.minX, dy: a.bounds.minY) }
        return shifted.allSatisfy { a.bounds.insetBy(dx: -2, dy: -2).contains($0) } ? shifted : out
    }

    static func quote(_ a: PDFAnnotation, _ page: PDFPage) -> String {
        if let edited = BookMarks.splitContents(a.contents ?? "").quote { return edited }
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
        let rel = Paths.relative(path)
        let f = rel.addingPercentEncoding(withAllowedCharacters: allowed) ?? rel
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
        h += "pdf: \(yaml(Paths.relative(pdfPath)))\n---\n\n"
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
        func entryText(_ n: MarginNote) -> String {
            let pageLink = "[p. \(n.pageLabel)](\(link(path: pdfPath, page: n.pageIndex + 1)))"
            let cite = entry.map { " [@\($0.key), p. \(n.pageLabel)]" } ?? ""
            var t = n.quote.isEmpty ? "**\(pageLink)**\(cite)\n\n" : "> “\(n.quote)” (\(pageLink))\(cite)\n\n"
            if !n.comment.isEmpty { t += n.comment + "\n\n" }
            return t
        }
        // Essential passages first, then everything else, each in page order
        let essential = notes.filter { $0.level == .essential }
        let rest = notes.filter { $0.level != .essential }
        if !essential.isEmpty {
            b += "## Essential\n\n"
            for n in essential { b += entryText(n) }
        }
        if !rest.isEmpty || notes.isEmpty {
            b += essential.isEmpty ? "## Marginalia\n\n" : "## Interesting\n\n"
            if notes.isEmpty { b += "*(no highlights yet)*\n\n" }
            for n in rest { b += entryText(n) }
        }
        return b + endMarker
    }

    /// "@key.md"
    static func noteFileName(key: String) -> String {
        "@" + key.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".md"
    }

    /// <notes folder>/@key.md for a PDF (named after the PDF when it has no citation details)
    static func notePath(pdfPath: String, entry: BibEntry?) -> String {
        let stem = ((pdfPath as NSString).lastPathComponent as NSString).deletingPathExtension
        return folder + "/" + noteFileName(key: entry?.key ?? stem)
    }

    /// the Obsidian vault this folder is inside (the nearest folder above it holding `.obsidian`), if any
    static func vaultRoot(_ folder: String) -> String? {
        var dir = folder
        while dir.count > 1 {
            if FileManager.default.fileExists(atPath: dir + "/.obsidian") { return dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }
    static func inVault(_ folder: String) -> Bool { vaultRoot(folder) != nil }

    /// Opens a note by vault name and path inside it. `open?path=` starts Obsidian but doesn't reliably go to the note.
    static func obsidianLink(note path: String, vault root: String) -> String? {
        guard path.hasPrefix(root + "/") else { return nil }
        let inside = (String(path.dropFirst(root.count + 1)) as NSString).deletingPathExtension
        guard let v = (root as NSString).lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
              let f = inside.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return "obsidian://open?vault=\(v)&file=\(f)"
    }
    /// are paper notes kept in an Obsidian vault? (labels say "Open in Obsidian" then)
    static var notesInVault: Bool { inVault(folder) }

    /// Open a paper note: in Obsidian when it's inside an Obsidian vault, otherwise in the default Markdown app.
    static func openNote(_ path: String) {
        if let root = vaultRoot((path as NSString).deletingLastPathComponent),
           let link = obsidianLink(note: path, vault: root), let url = URL(string: link),
           NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// Create or update <notes folder>/@key.md. Only the marginalia block is rewritten.
    static func mirror(pdfPath: String, entry: BibEntry?, notes: [MarginNote], summary: String, create: Bool = false) {
        let stem = ((pdfPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let key = entry?.key ?? stem
        let name = noteFileName(key: key)
        let fm = FileManager.default
        let url = URL(fileURLWithPath: folder).appendingPathComponent(name)
        let exists = fm.fileExists(atPath: url.path)
        guard Paths.writeNotes, exists || create || !notes.isEmpty || !summary.isEmpty else { return }
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
            // header: title + open the paper note
            HStack(spacing: 6) {
                Text("Highlights & Notes").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 9)
            .padding(.bottom, 4)

            // legend: the two kinds of highlight
            HStack(spacing: 14) {
                ForEach([HighlightLevel.essential, .interesting]) { level in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: level.nsColor.withAlphaComponent(0.9)))
                            .frame(width: 14, height: 10)
                        Text(level.name).font(.caption.weight(.medium))
                    }
                    .help(level == .essential ? "Essential: the few passages that matter most. Tick Essential on a card."
                                              : "Interesting: worth remembering. Every new highlight starts here.")
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

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
                    .onChange(of: viewer.spotlightNoteID) { id in
                        if let id = id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                    .onAppear {
                        if let id = viewer.spotlightNoteID {
                            DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
                        }
                    }
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Label("Select text, then press H to highlight it", systemImage: "highlighter")
                Label("Tick Essential for the passages that matter most", systemImage: "checkmark.square")
                Label("Type #tags in a note; click one to see them all", systemImage: "number")
                Label("Type a note under a highlight. It saves itself", systemImage: "square.and.pencil")
                Label("Click a card to see its passage in the PDF", systemImage: "arrow.turn.down.right")
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
    @State private var editingQuote = false
    @State private var quoteText = ""
    @FocusState private var focused: Bool

    /// a highlight on a photographed page: its text was read from the picture, so it can be corrected
    private var fromPhoto: Bool { note.annotation.page.map(PageLabels.isPhotoPage) ?? false }

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
                if let level = note.level {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: level.nsColor.withAlphaComponent(0.9)))
                        .frame(width: 12, height: 12)
                        .help(level.name)
                } else {
                    Image(systemName: "note.text").foregroundStyle(.secondary)
                }
                Button("Page \(note.pageLabel)") { viewer.reveal(note) }
                    .buttonStyle(.link)
                    .help("Go to this passage")
                Spacer()
                if fromPhoto && !note.quote.isEmpty {
                    Button {
                        quoteText = note.quote
                        editingQuote.toggle()
                    } label: {
                        Label(editingQuote ? "Done" : "Edit", systemImage: editingQuote ? "checkmark" : "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Correct the text read from the photo. It saves as you type.")
                }
                Button(role: .destructive) { viewer.removeHighlight(note.annotation) } label: {
                    Label("Remove", systemImage: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this highlight and its note")
            }
            if editingQuote {
                TextEditor(text: $quoteText)
                    .font(.callout)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .frame(height: min(260, max(70, CGFloat(quoteText.count / 34 + 2) * 16)))
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1))
                    .onChange(of: quoteText) { t in viewer.updateQuote(note, t) }
            } else if !note.quote.isEmpty {
                Text(note.quote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(fromPhoto ? nil : 5)
                    .textSelection(.enabled)
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
            if note.level != nil {
                // Essential or not: changes the highlight's colour (red-pink / yellow)
                Toggle(isOn: Binding(
                    get: { note.level == .essential },
                    set: { viewer.setLevel(note.annotation, $0 ? .essential : .interesting) })) {
                    Text("Essential").font(.callout.weight(note.level == .essential ? .semibold : .regular))
                }
                .toggleStyle(.checkbox)
                .help("Tick for the passages that matter most (red-pink). Unticked = Interesting (yellow).")
            }
            let tags = Marginalia.tags(in: text)
            if !tags.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(tags, id: \.self) { t in TagChip(tag: t) }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(viewer.spotlightNoteID == note.id ? Color.primary.opacity(0.55) : Color.secondary.opacity(0.15),
                    lineWidth: viewer.spotlightNoteID == note.id ? 1.5 : 1))
        .contentShape(Rectangle())
        // a click anywhere on the card (the note box too) shows its highlight in the PDF
        .simultaneousGesture(TapGesture().onEnded { viewer.reveal(note) })
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

// MARK: - Book pages from photos

/// One word or line read from a photo. Boxes are 0…1 of the image, measured from its bottom-left corner.
struct OCRWord { let text: String; let box: CGRect }
struct OCRLine { let text: String; let box: CGRect; let words: [OCRWord]; var confidence: Float = 1 }

/// The rules for reading a photographed page, kept apart from Apple's frameworks so --selftest can check them.
enum BookPages {
    static let noNumber = "?"
    static let cover = "cover"
    static let front = "front"

    /// "xiv" → 14. Lower case only, or ordinary capitalised words would count.
    static func roman(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 8, s.allSatisfy({ "ivxlc".contains($0) }) else { return nil }
        let value: [Character: Int] = ["i": 1, "v": 5, "x": 10, "l": 50, "c": 100]
        let v = s.map { value[$0] ?? 0 }
        var total = 0
        for i in v.indices { total += (i + 1 < v.count && v[i] < v[i + 1]) ? -v[i] : v[i] }
        guard total > 0, romanText(total) == s else { return nil }
        return total
    }
    static func romanText(_ n: Int) -> String {
        var left = n, out = ""
        for (v, t) in [(100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")] {
            while left >= v { out += t; left -= v }
        }
        return out
    }
    private static func arabic(_ s: String) -> Int? {
        guard !s.isEmpty, s.count <= 4, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), n >= 1, n < 3000 else { return nil }
        return n
    }
    /// Where a page belongs in a book: cover, front matter, roman pages, then numbered pages. nil = unknown.
    static func rank(_ label: String) -> Double? {
        if label == cover { return -3 }
        if label == front { return -2 }
        if let n = arabic(label) { return Double(n) }
        if let n = roman(label) { return -1 + Double(n) / 10_000 }
        return nil
    }
    /// The page number `steps` pages after this one (for renumbering): "12" → "13", "ix" → "x".
    static func counted(_ label: String, by steps: Int) -> String? {
        if let n = arabic(label) { return String(n + steps) }
        if let n = roman(label) { return romanText(n + steps) }
        return nil
    }

    /// The number printed on a page: on its own in the top or bottom line, or at either end of a running head.
    /// `cropped` means the photo was trimmed to the page, so "near the edge" can be measured.
    static func printedNumber(_ lines: [OCRLine], cropped: Bool, handwritten: Bool = true) -> String? {
        let ordered = lines.sorted { $0.box.midY > $1.box.midY }
        func nearEdge(_ l: OCRLine, top: Bool) -> Bool {
            !cropped || (top ? l.box.midY >= 0.87 : l.box.midY <= 0.13)
        }
        let top = ordered.prefix(2).filter { nearEdge($0, top: true) }
        let bottom = ordered.suffix(2).reversed().filter { nearEdge($0, top: false) }
        func clean(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;·•-–—|[]()\t")) }
        // a number like 1984 at the foot of a copyright page is a year, not a page
        func folio(_ s: String) -> Bool { (arabic(s).map { $0 < 1500 } ?? false) || roman(s) != nil }
        for l in top + bottom {
            let t = clean(l.text)
            if folio(t) { return t }
            // a number written in by hand, like "P95", "p. 95" or "pg. 95"
            let s = t.lowercased()
            if handwritten, s.hasPrefix("p") {
                let n = String(s.drop(while: { $0 == "p" || $0 == "g" || $0 == "." || $0 == " " }))
                if arabic(n) != nil, folio(n) { return n }
            }
        }
        for (group, strict) in [(Array(top), false), (Array(bottom), true)] {
            for l in group {
                let parts = clean(l.text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.count >= 2, parts.count <= 9 else { continue }
                for (n, rest) in [(parts[parts.count - 1], Array(parts.dropLast())), (parts[0], Array(parts.dropFirst()))] {
                    if folio(n), runningHead(rest, strict: strict) { return n }
                }
            }
        }
        return nil
    }
    /// Do these words look like a running head rather than a sentence, a footnote or "Chapter 3"?
    private static func runningHead(_ words: [String], strict: Bool) -> Bool {
        let last = (words.last ?? "").lowercased().trimmingCharacters(in: .punctuationCharacters)
        if ["chapter", "part", "section", "volume", "book", "figure", "fig", "table", "plate", "see"].contains(last) { return false }
        let letters = words.joined().filter { $0.isLetter }
        guard letters.count >= 3 else { return false }
        if letters.filter({ $0.isUppercase }).count * 10 >= letters.count * 7 { return true }
        if strict { return false }
        let wordsWithLetters = words.filter { $0.contains(where: { $0.isLetter }) }
        let capitalised = wordsWithLetters.filter { $0.first(where: { $0.isLetter })?.isUppercase == true }
        return !wordsWithLetters.isEmpty && (words.first?.first?.isUppercase ?? false) && capitalised.count * 10 >= wordsWithLetters.count * 6
    }

    /// Lines that could be a running head (a book or chapter title), without any page number.
    static func runningHeads(_ lines: [OCRLine], cropped: Bool) -> [String] {
        let ordered = lines.sorted { $0.box.midY > $1.box.midY }
        var out: [String] = []
        for l in ordered.prefix(2) where !cropped || l.box.midY >= 0.85 {
            var parts = l.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let f = parts.first, arabic(f) != nil || roman(f) != nil { parts.removeFirst() }
            if let f = parts.last, arabic(f) != nil || roman(f) != nil { parts.removeLast() }
            if !parts.isEmpty { out.append(parts.joined(separator: " ")) }
        }
        return out
    }

    /// Tidy up a run of photos in page order: a misread number between two good ones is corrected, and a missing
    /// one is filled in only when its neighbours prove what it must be. Anything else stays unknown (nil).
    static func fillGaps(_ labels: [String?]) -> [String?] {
        var out = labels
        func number(_ i: Int) -> Int? { out[i].flatMap(arabic) }
        if out.count >= 3 {
            for i in 1..<(out.count - 1) {
                if let a = number(i - 1), let b = number(i + 1), b - a == 2, number(i) != a + 1 { out[i] = String(a + 1) }
            }
        }
        var i = 0
        while i < out.count {
            guard out[i] == nil else { i += 1; continue }
            var j = i
            while j < out.count && out[j] == nil { j += 1 }
            if i > 0, j < out.count, let a = number(i - 1), let b = number(j), b - a == j - i + 1 {
                for k in i..<j { out[k] = String(a + (k - i) + 1) }
            }
            i = j
        }
        return out
    }

    /// Where a page of this rank goes among pages already in the PDF (unknown pages are stepped over).
    static func insertionIndex(rank: Double, among ranks: [Double?]) -> Int {
        for (i, r) in ranks.enumerated() {
            if let r = r, r > rank { return i }
        }
        return ranks.count
    }

    /// A valid ISBN as 13 digits (ISBN-10s are converted), or nil if the check digit is wrong: a misread digit
    /// must never look up the wrong book.
    static func isbn13(_ s: String) -> String? {
        let t = s.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
        if t.count == 13, t.hasPrefix("978") || t.hasPrefix("979") {
            let d = t.compactMap { $0.wholeNumberValue }
            guard d.count == 13 else { return nil }
            let sum = d.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) }
            return sum % 10 == 0 ? t : nil
        }
        guard t.count == 10 else { return nil }
        let d = t.map { $0 == "X" ? 10 : ($0.wholeNumberValue ?? 0) }
        if t.dropLast().contains("X") { return nil }
        let sum = d.enumerated().reduce(0) { $0 + $1.element * (10 - $1.offset) }
        guard sum % 11 == 0 else { return nil }
        let body = "978" + t.dropLast()
        let b = body.compactMap { $0.wholeNumberValue }
        let check = (10 - b.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) } % 10) % 10
        return body + String(check)
    }
    /// Every valid ISBN printed in some text, as 13 digits. Bare 10-digit numbers only count right after "ISBN".
    static func isbns(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9])[0-9][0-9\\- ]{8,15}[0-9Xx](?![0-9])") else { return [] }
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let s = ns.substring(with: m.range)
            guard let i = isbn13(s), !out.contains(i) else { continue }
            let digits = s.filter { $0.isNumber || $0 == "X" || $0 == "x" }
            if digits.count == 10 {
                let start = max(0, m.range.location - 24)
                let before = ns.substring(with: NSRange(location: start, length: m.range.location - start))
                guard before.lowercased().contains("isbn") else { continue }
            }
            out.append(i)
        }
        return out
    }
    /// The ISBNs in a library.bib `isbn` field, which may hold several separated by spaces.
    static func isbnList(_ field: String) -> [String] {
        field.components(separatedBy: CharacterSet(charactersIn: " ,;\n\t")).compactMap(isbn13)
    }

    /// Did this title come from this PDF? Most of its words must be in the PDF's first pages. It stops a DOI from
    /// someone else's paper, or a wrong title match, filling in the wrong details with no card to catch it.
    static func titleAppears(_ title: String, in text: String) -> Bool {
        let wanted = Set(BibIndex.fold(title.precomposedStringWithCompatibilityMapping).split(separator: " "))
        let page = Set(BibIndex.fold(text.precomposedStringWithCompatibilityMapping).split(separator: " "))
        guard !wanted.isEmpty else { return false }
        return wanted.filter { page.contains($0) }.count * 10 >= wanted.count * 7
    }

    /// A book's short title, folded for matching: no subtitle, no leading "The".
    static func shortTitle(_ title: String) -> String {
        let main = title.components(separatedBy: CharacterSet(charactersIn: ":;")).first ?? title
        var f = BibIndex.fold(main)
        for a in ["the ", "a ", "an "] where f.hasPrefix(a) { f = String(f.dropFirst(a.count)); break }
        return f
    }
    /// Is this running head the book's title? Whole title only, so a chapter title can't match by a stray word.
    static func headMatches(_ head: String, title: String) -> Bool {
        let t = shortTitle(title), h = shortTitle(head)
        guard !t.isEmpty else { return false }
        if h == t { return true }
        return t.split(separator: " ").count >= 2 && (" " + h + " ").contains(" " + t + " ")
    }
    /// The one book that the most running heads point to, or nil if none does or two tie.
    static func bookForHeads(_ heads: [[String]], books: [(key: String, title: String)]) -> String? {
        var score: [String: Int] = [:]
        for page in heads {
            for b in books where page.contains(where: { headMatches($0, title: b.title) }) { score[b.key, default: 0] += 1 }
        }
        guard let best = score.values.max(), score.values.filter({ $0 == best }).count == 1 else { return nil }
        return score.first { $0.value == best }?.key
    }

    /// Photos from different books, dropped together: a new ISBN starts a new book, and an unnumbered photo
    /// just before it (its cover) goes with it. Returns the photos' positions, grouped by book.
    static func groups(_ shots: [(isbns: [String], numbered: Bool)]) -> [[Int]] {
        var out: [[Int]] = [], current: [Int] = []
        var seen = Set<String>()
        for (i, s) in shots.enumerated() {
            let new = Set(s.isbns)
            if !new.isEmpty, !seen.isEmpty, new.isDisjoint(with: seen) {
                var moved: [Int] = []
                while let l = current.last, !shots[l].numbered, shots[l].isbns.isEmpty { moved.insert(current.removeLast(), at: 0) }
                if !current.isEmpty { out.append(current) }
                current = moved
                seen = []
            }
            current.append(i)
            seen.formUnion(new)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Labels for one book's photos, in order. The first photo counts as the cover if it has little text, no
    /// number and no ISBN, and the book has no cover yet. An ISBN page is front matter.
    static func labels(numbers: [String?], isbnPage: [Bool], characters: [Int], hasCover: Bool) -> [String] {
        let filled = fillGaps(numbers)
        return filled.indices.map { i in
            if let n = filled[i] { return n }
            if isbnPage[i] { return front }
            if i == 0 && !hasCover && characters[i] < 400 { return cover }
            return noNumber
        }
    }

    /// The share of the picture a four-cornered shape covers (corners in order, 0…1).
    static func area(_ p: [CGPoint]) -> Double {
        guard p.count == 4 else { return 0 }
        var s = 0.0
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4]
            s += Double(a.x * b.y - b.x * a.y)
        }
        return abs(s) / 2
    }

    /// Is this page lying on its side? Most of its longer lines run up the page rather than across it.
    /// How much this reads like the right way up. Sideways text comes back as one or two words to a line, and upside
    /// down text as nonsense, so whole lines of letters that contain everyday words only happen the right way up.
    static func readingScore(_ lines: [OCRLine]) -> Double {
        var score = 0.0, words = 0, everyday = 0
        for l in lines {
            let letters = l.text.filter { $0.isLetter }.count
            score += Double(letters) * Double(l.confidence) * (l.words.count >= 3 ? 1 : 0.1)
            words += l.words.count
            everyday += l.words.filter { commonWords.contains($0.text.lowercased().trimmingCharacters(in: .punctuationCharacters)) }.count
        }
        return score * (1 + 3 * Double(everyday) / Double(max(words, 1)))
    }
    private static let commonWords: Set<String> = ["the", "of", "and", "to", "in", "is", "that", "for", "it", "as", "with", "on", "be", "by", "this", "which", "are", "not",
                                                   "de", "la", "le", "et", "les", "des", "der", "die", "und", "das", "el", "que", "en", "il", "di", "che", "o", "e", "a"]
    /// Which of the four turns to use (0 is as it came). One of the others has to be clearly better.
    static func bestTurn(_ scores: [Double]) -> Int {
        guard let first = scores.first, let top = scores.max(), let best = scores.firstIndex(of: top) else { return 0 }
        return top > first * 1.3 + 1 ? best : 0
    }

    /// What a page's ink says when it is held one way round.
    struct InkReading {
        var lines: Double       // how sharply the ink falls into rows
        var lean: Double        // ink just above the body of the letters over ink just below it
    }
    /// Reads the ink of a page, about 1400 pixels on its long side. Printed lines make rows of ink, so `lines` is high when
    /// the page is level and low when it's on its side. More letters rise above the line (b, d, h, capitals) than drop
    /// below it (g, p, y), so `lean` is above 1 the right way up and below 1 upside down.
    /// Works in eight narrow strips, so a curved or slanted line of print still counts.
    static func inkReading(rgba: [UInt8], width w: Int, height h: Int) -> InkReading {
        guard w > 40, h > 40, rgba.count >= w * h * 4 else { return InkReading(lines: 0, lean: 1) }
        var sums = [Double](repeating: 0, count: (w + 1) * (h + 1))
        var gray = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            var row = 0.0
            for x in 0..<w {
                let p = (y * w + x) * 4
                let g = 0.299 * Double(rgba[p]) + 0.587 * Double(rgba[p + 1]) + 0.114 * Double(rgba[p + 2])
                gray[y * w + x] = g
                row += g
                sums[(y + 1) * (w + 1) + x + 1] = sums[y * (w + 1) + x + 1] + row
            }
        }
        // ink: clearly darker than its surroundings, so shadows don't count
        let r = max(w, h) / 40
        func isInk(_ x: Int, _ y: Int) -> Bool {
            let x0 = max(0, x - r), x1 = min(w, x + r + 1), y0 = max(0, y - r), y1 = min(h, y + r + 1)
            let total = sums[y1 * (w + 1) + x1] - sums[y0 * (w + 1) + x1] - sums[y1 * (w + 1) + x0] + sums[y0 * (w + 1) + x0]
            return gray[y * w + x] < total / Double((x1 - x0) * (y1 - y0)) * 0.75
        }
        // the middle of the picture: the edges are where neighbouring pages and tables show
        let left = w * 15 / 100, right = w * 85 / 100, top = h * 10 / 100, bottom = h * 90 / 100
        let strips = 8, strip = (right - left) / strips, rows = bottom - top
        guard strip > 0, rows > 8 else { return InkReading(lines: 0, lean: 1) }
        var lines = 0.0, above = 0.0, below = 0.0
        for s in 0..<strips {
            // lines of print on a photo slant a little, and not all the same way, so each strip is levelled first
            let x0 = left + s * strip
            var points: [(x: Int, y: Int)] = []
            for y in 0..<rows {
                for x in x0..<(x0 + strip) where isInk(x, top + y) { points.append((x - x0 - strip / 2, y)) }
            }
            var raw = [Double](repeating: 0, count: rows), sharpest = -1.0
            for step in -7...7 {
                var trial = [Double](repeating: 0, count: rows)
                let slant = Double(step) * 0.02
                for p in points {
                    let y = p.y + Int((Double(p.x) * slant).rounded())
                    if y >= 0, y < rows { trial[y] += 1 }
                }
                let sharpness = trial.reduce(0) { $0 + $1 * $1 }
                if sharpness > sharpest { sharpest = sharpness; raw = trial }
            }
            var p = [Double](repeating: 0, count: rows)
            for y in 0..<rows {
                p[y] = raw[y] * 0.5 + (y > 0 ? raw[y - 1] * 0.25 : 0) + (y < rows - 1 ? raw[y + 1] * 0.25 : 0)
            }
            let mean = p.reduce(0, +) / Double(rows)
            guard mean > 0 else { continue }
            lines += p.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(rows) / (mean * mean + 1e-6)
            // the body of each line of print: rows of more than half the usual full row of ink
            let sorted = p.sorted()
            let at = 0.85 * Double(rows - 1), low = Int(at), high = min(low + 1, rows - 1)
            let threshold = (sorted[low] + (sorted[high] - sorted[low]) * (at - Double(low))) * 0.5
            var y = 0
            while y < rows {
                guard p[y] > threshold else { y += 1; continue }
                var end = y
                while end < rows, p[end] > threshold { end += 1 }
                if y > 0, end < rows, (3...30).contains(end - y) {
                    let reach = max(2, (end - y) / 2)
                    above += p[max(0, y - reach)..<y].reduce(0, +)
                    below += p[end..<min(rows, end + reach)].reduce(0, +)
                }
                y = end
            }
        }
        return InkReading(lines: lines / Double(strips), lean: above / (below + 1))
    }
    /// Which way round to hold a page, from its ink read four ways, each a quarter turn on from the last.
    /// nil if the way it came is as good as any.
    static func turnFromInk(_ r: [InkReading]) -> Int? {
        guard r.count == 4 else { return nil }
        // rows of print across the other way: certainly on its side, so the only question is which side
        if min(r[1].lines, r[3].lines) > max(r[0].lines, r[2].lines) * 2 { return r[1].lean >= r[3].lean ? 1 : 3 }
        guard let top = r.map({ $0.lean }).max(), let best = r.firstIndex(where: { $0.lean == top }), best != 0 else { return nil }
        return top >= 1.08 && top >= r[0].lean + 0.1 && r[best].lines >= r[0].lines * 0.8 ? best : nil
    }

    /// The spaces-apart pieces of a line.
    static func wordRanges(_ s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let b = start { out.append(b..<i); start = nil }
            } else if start == nil { start = i }
            i = s.index(after: i)
        }
        if let b = start { out.append(b..<s.endIndex) }
        return out
    }
    /// Boxes for words when the OCR gives only the line's: share the line out by length.
    static func spread(_ words: [String], across box: CGRect) -> [OCRWord] {
        let total = words.reduce(0) { $0 + $1.count + 1 }
        guard total > 0 else { return [] }
        var x = box.minX
        return words.map { w in
            let width = box.width * CGFloat(w.count) / CGFloat(total)
            defer { x += box.width * CGFloat(w.count + 1) / CGFloat(total) }
            return OCRWord(text: w, box: CGRect(x: x, y: box.minY, width: width, height: box.height))
        }
    }

    /// How a hidden page marker is written inside the PDF.
    static let markerPrefix = "PDFSearch page: "
    static let photoMarkerPrefix = "PDFSearch photo page: "
    static func markerText(_ label: String, photo: Bool) -> String { (photo ? photoMarkerPrefix : markerPrefix) + label }
    static func markerLabel(_ contents: String) -> String? {
        for p in [photoMarkerPrefix, markerPrefix] where contents.hasPrefix(p) { return String(contents.dropFirst(p.count)) }
        return nil
    }
}

/// One passage you marked on a page: a yellow streak in the margin beside underlined lines.
/// Boxes are 0…1 of the page, from its bottom-left corner, one per line.
struct MarkedPassage {
    let boxes: [CGRect]
    let text: String
    let marginNotes: [String]
    var tags: [String] = []
    var corrected: String? = nil    // the exact text, when Claude has read the page
    var termOnly = false            // made just to hold a tag: no yellow mark beside it
}

/// Words you put in big pen parentheses, with where they are on the page.
struct KeyTerm {
    let tag: String
    let box: CGRect
    let text: String
    var boxes: [CGRect]? = nil      // one per line, when it's known to run across lines
}

/// Finds marked passages in a page's pixels. A yellow streak says "look here"; the pen underlines beside it say
/// where the passage starts and ends, because the streak itself is drawn roughly. Underlines with no yellow beside
/// them are left alone. `rgba` is 4 bytes a pixel, top row first.
enum BookMarks {
    /// The note a passage starts with: its #tags, and your handwriting beside it, if any was found.
    static func comment(_ p: MarkedPassage) -> String {
        var parts = p.tags.map { "#" + $0 }
        if !p.marginNotes.isEmpty { parts.append("Margin note (uncertain): " + p.marginNotes.joined(separator: " ")) }
        return parts.joined(separator: "\n")
    }

    /// A tag from the words inside parentheses: lower case, hyphens for spaces, no leading "a" or "the". It stops at
    /// punctuation that ends the term. nil if nothing in it is a real word (a stray mark around "of the").
    static func tag(_ words: [String], whole: Bool = false) -> (tag: String, used: Int)? {
        var kept: [String] = []
        var used = 0
        for w in words {
            used += 1
            let clean = w.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "-" }.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if !clean.isEmpty { kept.append(clean) }
            if !whole, let end = w.last, ")]:;,.!?".contains(end) { break }
        }
        let small: Set<String> = ["a", "an", "the", "of", "to", "and", "or", "in", "on", "by", "for", "at", "as", "with", "its", "their", "that", "this", "which", "these", "those"]
        while let f = kept.first, small.contains(f) { kept.removeFirst() }
        while let l = kept.last, small.contains(l) { kept.removeLast() }
        guard kept.contains(where: { $0.count >= 5 && !small.contains($0) }) else { return nil }
        return (kept.joined(separator: "-"), used)
    }

    /// Finds words in big pen parentheses. A parenthesis is a dark stroke taller than the print that bows outward: left
    /// for "(", right for ")". The bow is what tells it from a margin line or a printed stem.
    static func keyTerms(rgba: [UInt8], width w: Int, height h: Int, lines: [OCRLine]) -> [KeyTerm] {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return [] }
        let printed = lines.filter { $0.words.count >= 3 }
        // sizes come from the distance between lines: how tall a word's box is depends on what measured it
        let middles = printed.map { (1 - $0.box.midY) * CGFloat(h) }.sorted()
        let gaps = zip(middles, middles.dropFirst()).map { $1 - $0 }.filter { $0 > CGFloat(h) / 200 }.sorted()
        guard !gaps.isEmpty else { return [] }
        let lineGap = gaps[gaps.count / 2]
        let wordHeight = lineGap * 0.72, tallest = max(8, Int(wordHeight * 1.25))
        // pen and print: darker than their surroundings
        var gray = [Int](repeating: 0, count: w * h)
        for i in 0..<(w * h) { gray[i] = Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) + Int(rgba[i * 4 + 2]) }
        var sum = [Int](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += gray[y * w + x]
                sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
            }
        }
        let radius = max(3, h * 25 / 2400)
        var dark = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
            for x in 0..<w {
                let x0 = max(0, x - radius), x1 = min(w, x + radius + 1)
                let total = sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
                dark[y * w + x] = gray[y * w + x] * (x1 - x0) * (y1 - y0) * 100 < total * 80
            }
        }
        // for each dark pixel, the longest stroke ending there, allowed to lean a little on each row
        let steps = [0, 1, -1, 2, -2]
        var length = [Int32](repeating: 0, count: w * h)
        var from = [Int8](repeating: 0, count: w * h)
        for x in 0..<w where dark[x] { length[x] = 1 }
        for y in 1..<h {
            for x in 0..<w where dark[y * w + x] {
                var best: Int32 = 0, step: Int8 = 0
                for (k, s) in steps.enumerated() {
                    let px = x - s
                    if px >= 0, px < w, length[(y - 1) * w + px] > best { best = length[(y - 1) * w + px]; step = Int8(k) }
                }
                length[y * w + x] = best + 1
                from[y * w + x] = step
            }
        }
        // take the longest strokes first, and trace each back to measure its bow
        struct Stroke { let left: Int, right: Int, top: Int, bottom: Int, bow: Double }
        var ends: [Int] = []
        for i in 0..<(w * h) where Int(length[i]) >= tallest { ends.append(i) }
        ends.sort { length[$0] > length[$1] }
        var taken = [Bool](repeating: false, count: (h / 8 + 2) * (w / 8 + 2))
        let cells = w / 8 + 2
        var strokes: [Stroke] = []
        for e in ends {
            let y = e / w, x = e % w
            if taken[(y / 8) * cells + x / 8] { continue }
            let n = Int(length[e])
            var path: [Int] = []
            var px = x, py = y
            for _ in 0..<n {
                path.append(px)
                px -= steps[Int(from[py * w + px])]
                py -= 1
                if px < 0 || px >= w || py < 0 { break }
            }
            path.reverse()
            let low = path.min() ?? x, high = path.max() ?? x
            for row in max(0, (y - n) / 8)...(y / 8) {
                for col in max(0, low / 8 - 1)...min(cells - 1, high / 8 + 1) { taken[row * cells + col] = true }
            }
            guard let first = path.first, let last = path.last else { continue }
            let bow = Double(path[path.count / 2]) - Double(first + last) / 2
            strokes.append(Stroke(left: low, right: high, top: y - n, bottom: y, bow: bow))
        }
        var out: [KeyTerm] = []
        for line in printed {
            let middle = Int((1 - line.box.midY) * CGFloat(h))
            let a = Int(line.box.minX * CGFloat(w)), b = Int(line.box.maxX * CGFloat(w)), slack = Int(wordHeight)
            let here = strokes.filter { $0.top < middle && middle < $0.bottom && $0.left >= a - slack && $0.left <= b + slack }
            let rights = here.filter { $0.bow >= 3 }.map { $0.right }.sorted()
            var seen = Set<String>()
            for l in here.filter({ $0.bow <= -3 }).map({ $0.left }).sorted() {
                guard let r = rights.first(where: { $0 > l + slack }) else { continue }
                let inside = line.words.filter { let c = Int($0.box.midX * CGFloat(w)); return c > l && c < r }
                guard !inside.isEmpty, inside.count <= 6, let t = tag(inside.map { $0.text }), seen.insert(t.tag).inserted,
                      let one = inside.first else { continue }
                let used = inside.prefix(t.used)
                out.append(KeyTerm(tag: t.tag, box: used.dropFirst().reduce(one.box) { $0.union($1.box) }, text: used.map { $0.text }.joined(separator: " ")))
            }
        }
        return out.count > 5 ? [] : out      // that many on a page means a dark or blurred photo, not parentheses
    }

    /// Puts each term's tag on the passage it's inside; a term in no passage gets a small highlight of its own.
    static func attach(_ terms: [KeyTerm], to passages: [MarkedPassage]) -> [MarkedPassage] {
        var out = passages
        for t in terms {
            let centre = CGPoint(x: t.box.midX, y: t.box.midY)
            if let i = out.firstIndex(where: { p in p.boxes.contains { $0.insetBy(dx: -0.01, dy: -0.004).contains(centre) } }) {
                if !out[i].tags.contains(t.tag) { out[i].tags.append(t.tag) }
            } else {
                out.append(MarkedPassage(boxes: t.boxes ?? [t.box], text: t.text, marginNotes: [], tags: [t.tag],
                                         corrected: t.boxes == nil ? nil : t.text, termOnly: true))
            }
        }
        return out
    }

    /// A corrected quote is kept after your note in the highlight's comment, so it stays in the PDF and is searchable.
    static let quoteMark = "Edited quote: "
    static func splitContents(_ contents: String) -> (note: String, quote: String?) {
        let found = contents.hasPrefix(quoteMark) ? contents.range(of: quoteMark)
                                                  : contents.range(of: "\n" + quoteMark, options: .backwards)
        guard let r = found else { return (contents, nil) }
        let quote = contents[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let note = contents[..<r.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (note, quote.isEmpty ? nil : quote)
    }
    static func joinContents(note: String, quote: String?) -> String {
        guard let q = quote, !q.isEmpty else { return note }
        return note.isEmpty ? quoteMark + q : note + "\n\n" + quoteMark + q
    }

    /// Boxes on the same line joined into one, top line first, so a highlight that's been extended stays one
    /// box per line and its quote reads in order. (PDF boxes: y counts up from the bottom.)
    static func mergeLines(_ boxes: [CGRect]) -> [CGRect] {
        var out: [CGRect] = []
        for b in boxes.sorted(by: { $0.midY > $1.midY }) {
            if let l = out.last {
                let shared = min(l.maxY, b.maxY) - max(l.minY, b.minY)
                if shared * 2 >= min(l.height, b.height) { out[out.count - 1] = l.union(b); continue }
            }
            out.append(b)
        }
        return out
    }

    /// The rows each yellow streak covers, as (top, bottom) pixel rows.
    static func streaks(rgba: [UInt8], width w: Int, height h: Int) -> [(top: Int, bottom: Int)] {
        var rows = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Int(rgba[i]), g = Int(rgba[i + 1]), b = Int(rgba[i + 2])
                if r > 140, g > 128, b * 100 < 62 * min(r, g) { rows[y] += 1 }
            }
        }
        let enough = max(4, w * 12 / 1000), gap = max(2, h / 120), tallest = max(4, h / 50)
        var out: [(top: Int, bottom: Int)] = []
        var start: Int?, last = 0
        for y in 0..<h where rows[y] >= enough {
            if let s = start, y - last > gap {
                if last - s >= tallest { out.append((s, last)) }
                start = y
            } else if start == nil { start = y }
            last = y
        }
        if let s = start, last - s >= tallest { out.append((s, last)) }
        return out
    }

    /// Pen strokes: pixels darker than their surroundings (so shadows don't count), in long level runs. Letters
    /// are too short to count, which leaves the underlines.
    static func strokes(rgba: [UInt8], width w: Int, height h: Int) -> [Bool] {
        var gray = [Int](repeating: 0, count: w * h)
        for i in 0..<(w * h) { gray[i] = Int(rgba[i * 4]) + Int(rgba[i * 4 + 1]) + Int(rgba[i * 4 + 2]) }
        var sum = [Int](repeating: 0, count: (w + 1) * (h + 1))        // running totals, for a quick local average
        for y in 0..<h {
            var row = 0
            for x in 0..<w {
                row += gray[y * w + x]
                sum[(y + 1) * (w + 1) + x + 1] = sum[y * (w + 1) + x + 1] + row
            }
        }
        let radius = max(3, h * 25 / 2400), longest = max(6, h * 36 / 2400)
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let y0 = max(0, y - radius), y1 = min(h, y + radius + 1)
            var run = 0
            for x in 0...w {
                var dark = false
                if x < w {
                    let x0 = max(0, x - radius), x1 = min(w, x + radius + 1)
                    let total = sum[y1 * (w + 1) + x1] - sum[y0 * (w + 1) + x1] - sum[y1 * (w + 1) + x0] + sum[y0 * (w + 1) + x0]
                    dark = gray[y * w + x] * (x1 - x0) * (y1 - y0) * 100 < total * 72
                }
                if dark { run += 1; continue }
                if run >= longest { for k in (x - run)..<x { out[y * w + k] = true } }
                run = 0
            }
        }
        return out
    }

    /// Is this word underlined? Looks in a band under it for pen strokes along at least half its width.
    private static func underlined(_ word: OCRWord, strokes: [Bool], width w: Int, height h: Int) -> Bool {
        let wordHeight = word.box.height * CGFloat(h)
        let bottom = (1 - word.box.minY) * CGFloat(h)
        let y0 = max(0, Int(bottom - wordHeight * 0.25)), y1 = min(h, Int(bottom + wordHeight * 0.75))
        let x0 = max(0, Int(word.box.minX * CGFloat(w))), x1 = min(w, Int(word.box.maxX * CGFloat(w)))
        guard x1 > x0, y1 > y0 else { return false }
        var covered = 0
        for x in x0..<x1 {
            for y in y0..<y1 where strokes[y * w + x] { covered += 1; break }
        }
        return covered * 2 >= x1 - x0
    }

    static func passages(rgba: [UInt8], width w: Int, height h: Int, lines: [OCRLine], underlines: Bool = true) -> [MarkedPassage] {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return [] }
        let found = streaks(rgba: rgba, width: w, height: h)
        guard !found.isEmpty else { return [] }
        let ink = strokes(rgba: rgba, width: w, height: h)
        // the text column, so handwriting in the margin isn't taken for the book
        let printed = lines.filter { $0.words.count >= 4 }
        let lefts = printed.map { $0.box.minX }.sorted(), rights = printed.map { $0.box.maxX }.sorted()
        guard !lefts.isEmpty else { return [] }
        let left = lefts[lefts.count / 2], right = rights[rights.count / 2]
        func inMargin(_ l: OCRLine) -> Bool { l.box.maxX < left || l.box.minX > right }
        func row(_ l: OCRLine) -> CGFloat { (1 - l.box.midY) * CGFloat(h) }
        var out: [MarkedPassage] = []
        for s in found {
            func beside(_ l: OCRLine, _ slack: CGFloat) -> Bool {
                let pad = l.box.height * CGFloat(h) * slack
                return row(l) >= CGFloat(s.top) - pad && row(l) <= CGFloat(s.bottom) + pad
            }
            let near = lines.filter { !inMargin($0) && beside($0, 0.5) }.sorted { row($0) < row($1) }
            let marks = near.map { l in l.words.map { underlines && underlined($0, strokes: ink, width: w, height: h) } }
            var chosen: [(line: OCRLine, from: Int)] = []
            // one stray word doesn't start a passage: the first line needs two
            let start = marks.firstIndex { m in m.filter { $0 }.count >= 2 } ?? marks.firstIndex { $0.contains(true) }
            if let first = start, let last = marks.lastIndex(where: { $0.contains(true) }), first <= last {
                // the first line starts at its first underlined word; the rest are whole lines
                for i in first...last { chosen.append((near[i], i == first ? (marks[i].firstIndex(of: true) ?? 0) : 0)) }
            } else {
                chosen = near.filter { beside($0, 0) }.map { ($0, 0) }     // yellow with no underline: trust the yellow
            }
            var boxes: [CGRect] = []
            var words: [String] = []
            for c in chosen {
                let part = c.line.words.dropFirst(c.from)
                guard let one = part.first else { continue }
                boxes.append(part.dropFirst().reduce(one.box) { $0.union($1.box) })
                words += part.map { $0.text }
            }
            guard !boxes.isEmpty else { continue }
            let notes = lines.filter { inMargin($0) && beside($0, 1) }.map { $0.text }
            out.append(MarkedPassage(boxes: boxes, text: words.joined(separator: " "), marginNotes: notes))
        }
        return out
    }
}

/// What Claude read from a page photo, if you've added an API key in Settings.
struct ClaudePage {
    var number: String?
    var passages: [(text: String, note: String)]
    var terms: [String]
    var before: [String] = []       // for each term, the printed words just before it
}

/// The request and reply for Claude reading a page, kept apart from the network so --selftest can check them.
enum ClaudeReading {
    static func prompt(style: MarkingStyle = .mine) -> String {
        let number = style.handwrittenPageNumbers ? "printed or written in by hand (for example, P95, p. 95 and pg. 95 all mean 95)" : "as printed"
        let terms = style.parenthesisTags
            ? "one object for each word or phrase the reader enclosed in big hand-drawn parentheses or a hand-drawn circle: {\"term\": ..., \"before\": ...}. term: all the printed words inside the marks, exactly as printed, from just after the opening mark to just before the closing mark, even across lines. before: the three printed words just before the term. Ignore printed parentheses. An empty list if there are none."
            : "an empty list."
        var passages = "an empty list."
        if style.marginStreaks {
            let extent = style.underlines
                ? "Each passage runs from the first printed word the pen underline reaches beside the streak to the last underlined word. Follow the pen line from line to line: it can wander or cut through the letters. If it carries on past the end of the streak without a break, keep following it to where it stops. Leave out words beside the streak with no underline. If nothing beside the streak is underlined, take the whole lines beside it."
                : "Each passage is the whole lines beside the streak."
            passages = """
            one object for each coloured streak in the margin, top to bottom, including pale or short ones: {"text": ..., "note": ...}. Two streaks are two passages, even when close together.
            \(extent)
            text: the exact printed words of that passage, with its printed spelling, accents and punctuation, and with no line-end hyphens. Leave out footnote numbers.
            note: everything written or drawn by hand in the margin beside that passage: words as written, a star as *, a question mark as ?, an arrow as →. An empty string if there is nothing.
            """
        }
        var s = """
        This is a photo of a page from a printed book that a reader may have marked. Look closely: the pen lines are thin. Reply with JSON only, no other text:
        {"page": ..., "terms": [...], "passages": [...]}

        page: the page number, \(number), as a string of digits or lower-case roman numerals. null if there is none.
        terms: \(terms)
        passages: \(passages)
        """
        let more = style.noteForClaude.trimmingCharacters(in: .whitespacesAndNewlines)
        if !more.isEmpty { s += "\n\nHow this reader marks pages, in their own words: " + more }
        return s
    }

    /// Reads Claude's reply, tolerating anything around the JSON. nil if it can't be understood.
    static func parse(_ reply: String) -> ClaudePage? {
        guard let a = reply.firstIndex(of: "{"), let b = reply.lastIndex(of: "}"), a < b,
              let data = String(reply[a...b]).data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var number = (j["page"] as? String)?.trimmingCharacters(in: .whitespaces).lowercased()
        if let n = j["page"] as? Int { number = String(n) }
        if let n = number, BookPages.rank(n) == nil || n == BookPages.cover || n == BookPages.front { number = nil }
        let raw = (j["terms"] as? [Any]) ?? []
        let terms = raw.map { ($0 as? String) ?? (($0 as? [String: Any])?["term"] as? String) ?? "" }
        let before = raw.map { (($0 as? [String: Any])?["before"] as? String) ?? "" }
        let passages = ((j["passages"] as? [[String: Any]]) ?? []).map {
            (text: ($0["text"] as? String) ?? "", note: ($0["note"] as? String) ?? "")
        }
        return ClaudePage(number: number, passages: passages, terms: terms, before: before)
    }

    /// The page's words in reading order, broken at punctuation, so "politics—which" matches however it was read.
    private struct Piece { let text: [UInt32]; let row: Int; let word: Int }
    private static func rows(_ lines: [OCRLine]) -> [[OCRWord]] {
        var out: [[OCRWord]] = []
        var last: OCRLine?
        for l in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let p = last, !out.isEmpty, abs(p.box.midY - l.box.midY) < min(p.box.height, l.box.height) / 2 { out[out.count - 1] += l.words }
            else { out.append(l.words) }
            last = l
        }
        return out.map { $0.sorted { $0.box.minX < $1.box.minX } }
    }
    private static func pieces(_ text: String) -> [[UInt32]] {
        BibIndex.fold(text).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.unicodeScalars.map { $0.value } }
    }
    /// Close enough to be the same word misread: 2 for the same, 1 for a slip or two, -1 for different.
    private static func likeness(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a == b { return 2 }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 2 else { return -1 }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let saved = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = saved
            }
        }
        return row[b.count] * 4 <= max(a.count, b.count) ? 1 : -1
    }
    /// Every place these words appear on the page, best first, none overlapping.
    private static func places(_ wanted: [[UInt32]], in page: [Piece]) -> [(start: Int, end: Int, score: Int)] {
        let n = wanted.count, m = page.count
        guard n > 0, m > 0 else { return [] }
        var score = [Int](repeating: 0, count: m + 1), from = Array(0...m)
        for i in 1...n {
            var nextScore = [Int](repeating: -i, count: m + 1), nextFrom = from
            for j in 1...m {
                let across = score[j - 1] + likeness(wanted[i - 1], page[j - 1].text)
                let down = score[j] - 1, along = nextScore[j - 1] - 1
                if across >= down && across >= along { nextScore[j] = across; nextFrom[j] = from[j - 1] }
                else if down >= along { nextScore[j] = down; nextFrom[j] = from[j] }
                else { nextScore[j] = along; nextFrom[j] = nextFrom[j - 1] }
            }
            score = nextScore; from = nextFrom
        }
        var found = (1...m).filter { score[$0] >= max(2, n) && from[$0] < $0 }.map { (start: from[$0], end: $0 - 1, score: score[$0]) }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.start < $1.start }
        var kept: [(start: Int, end: Int, score: Int)] = []
        for f in found where !kept.contains(where: { $0.start <= f.end && f.start <= $0.end }) { kept.append(f) }
        return kept
    }
    /// One box for each line these pieces of the page cover, top line first.
    private static func boxes(_ start: Int, _ end: Int, _ page: [Piece], _ rows: [[OCRWord]]) -> [CGRect] {
        var out: [CGRect] = []
        var i = start
        while i <= end {
            let row = page[i].row, first = page[i].word
            var last = first
            while i <= end, page[i].row == row { last = page[i].word; i += 1 }
            let words = rows[row][first...last]
            if let one = words.first { out.append(words.dropFirst().reduce(one.box) { $0.union($1.box) }) }
        }
        return out
    }
    private static func index(_ rows: [[OCRWord]]) -> [Piece] {
        var page: [Piece] = []
        for (r, row) in rows.enumerated() {
            for (w, word) in row.enumerated() { page += pieces(word.text).map { Piece(text: $0, row: r, word: w) } }
        }
        return page
    }

    /// Where a passage is on the page, one box per line. The words came from Claude and the positions from the Mac's
    /// reading, so they're matched allowing for misread words. Empty if it can't be found.
    static func locate(_ text: String, in lines: [OCRLine]) -> [CGRect] {
        let layout = rows(lines), page = index(layout)
        guard let best = places(pieces(text), in: page).first else { return [] }
        return boxes(best.start, best.end, page, layout)
    }
    /// Where a term is. The words before it tell one appearance from another.
    static func locate(term: String, before: String, in lines: [OCRLine]) -> [CGRect] {
        let layout = rows(lines), page = index(layout)
        let found = places(pieces(term), in: page)
        let context = pieces(before)
        func fit(_ f: (start: Int, end: Int, score: Int)) -> Int {
            let lead = page[max(0, f.start - context.count - 2)..<f.start]
            return context.filter { c in lead.contains { likeness($0.text, c) > 0 } }.count
        }
        guard let top = found.first else { return [] }
        let best = found.reduce(top) { fit($1) > fit($0) ? $1 : $0 }
        return boxes(best.start, best.end, page, layout)
    }

    static let longestTag = 12     // words

    /// Uses what Claude read: which passages are marked and where they start and stop, their exact words, margin
    /// notes and tags. What software found stays only if Claude found no passages at all.
    static func apply(_ page: ClaudePage, to passages: [MarkedPassage], lines: [OCRLine]) -> [MarkedPassage] {
        var out: [MarkedPassage] = []
        for p in page.passages {
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let note = p.note.trimmingCharacters(in: .whitespacesAndNewlines)
            let found = locate(text, in: lines)
            // a quote that can't be placed still shouldn't be lost: it goes on the top line
            let boxes = found.isEmpty ? Array(lines.sorted { $0.box.midY > $1.box.midY }.prefix(1).map { $0.box }) : found
            guard !boxes.isEmpty else { continue }
            out.append(MarkedPassage(boxes: boxes, text: text, marginNotes: note.isEmpty ? [] : [note], tags: [], corrected: text))
        }
        if out.isEmpty {
            out = passages.filter { !$0.termOnly }
            out = out.map { MarkedPassage(boxes: $0.boxes, text: $0.text, marginNotes: $0.marginNotes, tags: [], corrected: $0.corrected) }
        }
        var terms: [KeyTerm] = []
        for (i, t) in page.terms.enumerated() {
            let words = t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let before = i < page.before.count ? page.before[i] : ""
            let boxes = locate(term: t, before: before, in: lines)
            guard let first = boxes.first else { continue }
            // a whole sentence in parentheses is a passage, not a tag
            if words.count > longestTag {
                out.append(MarkedPassage(boxes: boxes, text: t, marginNotes: [], tags: [], corrected: t))
                continue
            }
            guard let tag = BookMarks.tag(words, whole: true)?.tag else { continue }
            terms.append(KeyTerm(tag: tag, box: first, text: t, boxes: boxes))
        }
        // a marked word that's also a tag needs only the one highlight
        let same = Set(terms.map { BibIndex.fold($0.text) })
        out.removeAll { $0.marginNotes.isEmpty && same.contains(BibIndex.fold($0.text)) }
        return BookMarks.attach(terms, to: out)
    }
}


/// How someone marks their books, so that one person's habits aren't built into the app. It's a small file in the
/// Book Photos folder, which Settings edits. With no file, nothing is looked for and photos become plain pages.
struct MarkingStyle: Codable, Equatable {
    var marginStreaks = false           // a coloured streak in the margin marks a passage
    var underlines = false              // pen underlines beside the streak pick out the exact words
    var parenthesisTags = false         // big pen parentheses around a term make it a #tag
    var handwrittenPageNumbers = false  // a page number written in by hand, like P95
    var noteForClaude = ""              // anything else, in plain words, for Claude to go by

    static let fileName = "Marking Style.json"
    /// Everything on, the way the code was first written. Only the tests rely on it.
    static var mine: MarkingStyle { MarkingStyle(marginStreaks: true, underlines: true, parenthesisTags: true, handwrittenPageNumbers: true) }
    init(marginStreaks: Bool = false, underlines: Bool = false, parenthesisTags: Bool = false, handwrittenPageNumbers: Bool = false, noteForClaude: String = "") {
        self.marginStreaks = marginStreaks; self.underlines = underlines; self.parenthesisTags = parenthesisTags
        self.handwrittenPageNumbers = handwrittenPageNumbers; self.noteForClaude = noteForClaude
    }
    /// A file edited by hand can leave things out: whatever's missing counts as off.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        marginStreaks = (try? c.decode(Bool.self, forKey: .marginStreaks)) ?? false
        underlines = (try? c.decode(Bool.self, forKey: .underlines)) ?? false
        parenthesisTags = (try? c.decode(Bool.self, forKey: .parenthesisTags)) ?? false
        handwrittenPageNumbers = (try? c.decode(Bool.self, forKey: .handwrittenPageNumbers)) ?? false
        noteForClaude = (try? c.decode(String.self, forKey: .noteForClaude)) ?? ""
    }
    static func load(from folder: String) -> MarkingStyle {
        guard let d = FileManager.default.contents(atPath: folder + "/" + fileName),
              let s = try? JSONDecoder().decode(MarkingStyle.self, from: d) else { return MarkingStyle() }
        return s
    }
    @discardableResult func save(to folder: String) -> Bool {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? e.encode(self), (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else { return false }
        return (try? d.write(to: URL(fileURLWithPath: folder + "/" + MarkingStyle.fileName), options: .atomic)) != nil
    }
}

/// Straightens a photographed page using its own lines of print, which ought to be straight and level. Works out how
/// the photo bends them, and undoes that: gently, on this Mac, moving the pixels and adding nothing, so pen marks survive.
enum PageFlattener {
    struct Model {
        var degree: Int
        var px: [Double], py: [Double]              // where each straight point came from in the photo
        var left: Double, right: Double, top: Double, bottom: Double     // the text block once straight
    }
    private static func powers(_ degree: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        for i in 0...degree { for j in 0...degree where i + j <= degree + 1 { out.append((i, j)) } }
        return out
    }
    private static func basis(_ u: Double, _ v: Double, _ m: (left: Double, right: Double, top: Double, bottom: Double), _ terms: [(Int, Int)]) -> [Double] {
        let a = (u - (m.left + m.right) / 2) / max((m.right - m.left) / 2, 1), b = (v - (m.top + m.bottom) / 2) / max((m.bottom - m.top) / 2, 1)
        var ua = [1.0], vb = [1.0]
        for k in 1..<8 { ua.append(ua[k - 1] * a); vb.append(vb[k - 1] * b) }
        return terms.map { ua[$0.0] * vb[$0.1] }
    }
    /// Solves the best fit of rows × answer = wanted. nil if the rows don't pin it down.
    private static func solve(_ rows: [[Double]], _ wanted: [[Double]]) -> [[Double]]? {
        guard let n = rows.first?.count else { return nil }
        let answers = wanted.count
        var a = [[Double]](repeating: [Double](repeating: 0, count: n + answers), count: n)
        for (r, row) in rows.enumerated() {
            for i in 0..<n {
                for j in 0..<n { a[i][j] += row[i] * row[j] }
                for k in 0..<answers { a[i][n + k] += row[i] * wanted[k][r] }
            }
        }
        for i in 0..<n { a[i][i] += 1e-9 * Double(rows.count) }
        for i in 0..<n {
            var pivot = i
            for r in i..<n where abs(a[r][i]) > abs(a[pivot][i]) { pivot = r }
            guard abs(a[pivot][i]) > 1e-12 else { return nil }
            a.swapAt(i, pivot)
            for r in 0..<n where r != i {
                let f = a[r][i] / a[i][i]
                if f != 0 { for c in i..<(n + answers) { a[r][c] -= f * a[i][c] } }
            }
        }
        return (0..<answers).map { k in (0..<n).map { a[$0][n + k] / a[$0][$0] } }
    }
    private static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }

    /// The edge of the text block: where most lines end, line by line. Short lines and indents are ignored.
    private static func edge(_ ends: [Double], rows: [Double], outward: Double, tolerance: Double) -> [Double]? {
        let order = rows.indices.sorted { rows[$0] < rows[$1] }
        let bands = 5
        guard order.count >= bands * 2 else { return nil }
        var points: [(y: Double, x: Double)] = []
        for b in 0..<bands {
            let part = order[(b * order.count / bands)..<((b + 1) * order.count / bands)]
            let xs = part.map { ends[$0] * outward }.sorted()
            points.append((rows[part[part.startIndex + part.count / 2]], xs[xs.count * 4 / 5] * outward))
        }
        let mid = median(rows), span = max((rows.max() ?? 1) - (rows.min() ?? 0), 1)
        func term(_ y: Double) -> Double { (y - mid) / span }
        guard var c = solve(points.map { [1, term($0.y)] }, [points.map { $0.x }])?.first else { return nil }
        c.append(0)
        for _ in 0..<3 {
            func at(_ y: Double) -> Double { c[0] + c[1] * term(y) + c[2] * term(y) * term(y) }
            let near = rows.indices.filter { abs(ends[$0] - at(rows[$0])) < tolerance }
            guard near.count >= 6, let f = solve(near.map { [1, term(rows[$0]), term(rows[$0]) * term(rows[$0])] }, [near.map { ends[$0] }])?.first else { return nil }
            c = f
        }
        return [c[0], c[1], c[2], mid, span]
    }
    private static func edgeAt(_ c: [Double], _ y: Double) -> Double { let t = (y - c[3]) / c[4]; return c[0] + c[1] * t + c[2] * t * t }

    /// Works out how the page is bent. nil if there isn't enough print to go on, or the answer isn't believable.
    static func fit(_ lines: [OCRLine], width w: Int, height h: Int) -> Model? {
        // left and right ends of each word, in pixels from the top left; a line with no real word positions says nothing
        struct Line { var x0: [Double], x1: [Double], y: [Double] }
        let W = Double(w), H = Double(h)
        let all: [Line] = lines.compactMap { l in
            let ws = l.words.filter { $0.box.width > 0 }.sorted { $0.box.minX < $1.box.minX }
            guard ws.count >= 3 else { return nil }
            let ys = ws.map { (1 - Double($0.box.midY)) * H }
            if ws.count >= 5, Set(ys).count == 1 { return nil }
            return Line(x0: ws.map { Double($0.box.minX) * W }, x1: ws.map { Double($0.box.maxX) * W }, y: ys)
        }
        let wide = all.filter { $0.y.count >= 5 }
        guard wide.count >= 10 else { return nil }
        let a0 = median(wide.compactMap { $0.x0.first }), b0 = median(wide.compactMap { $0.x1.last })
        let column = b0 - a0
        guard column > W * 0.3 else { return nil }
        // only this page's text: a neighbouring page's lines start past it
        let body = all.filter { l in
            guard let s = l.x0.first, let e = l.x1.last else { return false }
            return s < b0 - column * 0.25 && e > a0 && e < b0 + column * 0.12 && s > a0 - column * 0.12
        }
        guard body.count >= 10 else { return nil }
        let xm = (a0 + b0) / 2
        let rows: [Double] = body.map { l in
            let cx = zip(l.x0, l.x1).map { ($0 + $1) / 2 }
            let n = Double(cx.count), mx = cx.reduce(0, +) / n, my = l.y.reduce(0, +) / n
            let d = cx.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
            let slope = d > 0 ? zip(cx, l.y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / d : 0
            return my + slope * (min(max(xm, cx.min() ?? xm), cx.max() ?? xm) - mx)
        }
        guard let cL = edge(body.compactMap { $0.x0.first }, rows: rows, outward: -1, tolerance: column * 0.03),
              let cR = edge(body.compactMap { $0.x1.last }, rows: rows, outward: 1, tolerance: column * 0.03) else { return nil }
        let middle = median(rows), XL = edgeAt(cL, middle), XR = edgeAt(cR, middle)
        guard XR - XL > column * 0.7 else { return nil }
        var ids: [Int] = [], sx: [Double] = [], sy: [Double] = []
        for (i, l) in body.enumerated() {
            for k in l.y.indices { for x in [l.x0[k], l.x1[k]] { ids.append(i); sx.append(x); sy.append(l.y[k]) } }
        }
        func attempt(_ degree: Int) -> Model? {
            let terms = powers(degree)
            var rows = rows
            var keep = [Bool](repeating: true, count: sx.count)
            var px: [Double] = [], py: [Double] = []
            var frame = (left: XL, right: XR, top: rows.min() ?? 0, bottom: rows.max() ?? H)
            for _ in 0..<8 {
                frame = (XL, XR, rows.min() ?? 0, rows.max() ?? H)
                let us: [Double] = sx.indices.map { i in
                    let y = rows[ids[i]], l = edgeAt(cL, y), r = edgeAt(cR, y)
                    return XL + (sx[i] - l) / max(r - l, 1) * (XR - XL)
                }
                let table = sx.indices.map { basis(us[$0], rows[ids[$0]], frame, terms) }
                let used = sx.indices.filter { keep[$0] }
                guard used.count > terms.count * 4,
                      let f = solve(used.map { table[$0] }, [used.map { sx[$0] }, used.map { sy[$0] }]) else { return nil }
                px = f[0]; py = f[1]
                var ex = [Double](repeating: 0, count: sx.count), ey = ex
                for i in sx.indices {
                    ex[i] = zip(table[i], px).reduce(0) { $0 + $1.0 * $1.1 } - sx[i]
                    ey[i] = zip(table[i], py).reduce(0) { $0 + $1.0 * $1.1 } - sy[i]
                }
                var off = [[Double]](repeating: [], count: body.count)
                for i in used { off[ids[i]].append(ey[i]) }
                for i in rows.indices where off[i].count >= 2 { rows[i] -= median(off[i]) }
                let errors = sx.indices.map { (ex[$0] * ex[$0] + ey[$0] * ey[$0]).squareRoot() }
                let sigma = median(used.map { errors[$0] }) * 1.48
                for i in sx.indices { keep[i] = errors[i] < max(3 * sigma, H * 0.002) }
            }
            let m = Model(degree: degree, px: px, py: py, left: frame.left, right: frame.right, top: frame.top, bottom: frame.bottom)
            return believable(m, height: H) ? m : nil
        }
        return attempt(3) ?? attempt(2)
    }
    private static func source(_ m: Model, _ terms: [(Int, Int)], _ u: Double, _ v: Double) -> (x: Double, y: Double) {
        let c = min(max(u, m.left), m.right), d = min(max(v, m.top), m.bottom)
        let b = basis(c, d, (m.left, m.right, m.top, m.bottom), terms)
        return (zip(b, m.px).reduce(0) { $0 + $1.0 * $1.1 } + u - c, zip(b, m.py).reduce(0) { $0 + $1.0 * $1.1 } + v - d)
    }
    /// A page bends gently: nothing moves far, folds over, or is squeezed or stretched much.
    private static func believable(_ m: Model, height H: Double) -> Bool {
        let terms = powers(m.degree)
        let n = 14
        let du = (m.right - m.left) / Double(n), dv = (m.bottom - m.top) / Double(n)
        guard du > 0, dv > 0 else { return false }
        for i in 0...n {
            for j in 0...n {
                let u = m.left + du * Double(i), v = m.top + dv * Double(j)
                let p = source(m, terms, u, v)
                guard ((p.x - u) * (p.x - u) + (p.y - v) * (p.y - v)).squareRoot() < H * 0.15 else { return false }
                if i < n { let g = (source(m, terms, u + du, v).x - p.x) / du; guard g > 0.55, g < 1.8 else { return false } }
                if j < n { let g = (source(m, terms, u, v + dv).y - p.y) / dv; guard g > 0.7, g < 1.4 else { return false } }
            }
        }
        return true
    }

    /// Makes the straightened picture. Anything that would come from beyond the photo is left white.
    static func flatten(rgba: [UInt8], width w: Int, height h: Int, _ m: Model) -> [UInt8] {
        let terms = powers(m.degree), step = 16
        let gw = w / step + 2, gh = h / step + 2
        var gx = [Float](repeating: 0, count: gw * gh), gy = gx
        for j in 0..<gh {
            for i in 0..<gw {
                let p = source(m, terms, Double(i * step), Double(j * step))
                gx[j * gw + i] = Float(p.x); gy[j * gw + i] = Float(p.y)
            }
        }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        rgba.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                for y in 0..<h {
                    let j = y / step
                    let fy = Float(y - j * step) / Float(step)
                    for x in 0..<w {
                        let i = x / step
                        let fx = Float(x - i * step) / Float(step)
                        let a = j * gw + i, b = a + 1, c = a + gw, d = c + 1
                        let top = gx[a] + (gx[b] - gx[a]) * fx, low = gx[c] + (gx[d] - gx[c]) * fx
                        let ox = top + (low - top) * fy
                        let top2 = gy[a] + (gy[b] - gy[a]) * fx, low2 = gy[c] + (gy[d] - gy[c]) * fx
                        let oy = top2 + (low2 - top2) * fy
                        guard ox >= 0, oy >= 0, ox < Float(w - 1), oy < Float(h - 1) else { continue }
                        let ix = Int(ox), iy = Int(oy)
                        let tx = ox - Float(ix), ty = oy - Float(iy)
                        let p = (iy * w + ix) * 4, q = p + w * 4
                        for k in 0..<3 {
                            let t = Float(src[p + k]) + (Float(src[p + 4 + k]) - Float(src[p + k])) * tx
                            let l = Float(src[q + k]) + (Float(src[q + 4 + k]) - Float(src[q + k])) * tx
                            dst[(y * w + x) * 4 + k] = UInt8(t + (l - t) * ty + 0.5)
                        }
                    }
                }
            }
        }
        return out
    }

    /// Makes the paper white and takes out shadows: each colour is divided by the bare paper around it, so pen and
    /// print stay dark and yellow stays yellow, however dim the photo.
    static func whiten(rgba: [UInt8], width w: Int, height h: Int) -> [UInt8] {
        let s = 8, sw = w / s + 1, sh = h / s + 1
        var out = rgba
        var shape = [Double](repeating: 0, count: 4096)
        for i in shape.indices { shape[i] = pow(Double(i) / 4095, 1.3) * 255 }
        for k in 0..<3 {
            // a small copy, the brightest nearby paper in it, softened
            var small = [Float](repeating: 0, count: sw * sh), count = small
            for y in 0..<h { for x in 0..<w { let c = y / s * sw + x / s; small[c] += Float(rgba[(y * w + x) * 4 + k]); count[c] += 1 } }
            for i in small.indices where count[i] > 0 { small[i] /= count[i] }
            func sweep(_ a: [Float], radius r: Int, combine: ([Float]) -> Float) -> [Float] {
                var b = a
                for y in 0..<sh {
                    for x in 0..<sw {
                        var part: [Float] = []
                        for d in -r...r { let t = x + d; if t >= 0, t < sw { part.append(a[y * sw + t]) } }
                        b[y * sw + x] = combine(part)
                    }
                }
                var c = b
                for y in 0..<sh {
                    for x in 0..<sw {
                        var part: [Float] = []
                        for d in -r...r { let t = y + d; if t >= 0, t < sh { part.append(b[t * sw + x]) } }
                        c[y * sw + x] = combine(part)
                    }
                }
                return c
            }
            var paper = sweep(small, radius: 6) { $0.max() ?? 0 }
            for _ in 0..<3 { paper = sweep(paper, radius: 4) { $0.reduce(0, +) / Float($0.count) } }
            for y in 0..<h {
                let v = Float(y) / Float(s), j = min(Int(v), sh - 2), fy = v - Float(j)
                for x in 0..<w {
                    let u = Float(x) / Float(s), i = min(Int(u), sw - 2), fx = u - Float(i)
                    let a = j * sw + i
                    let top = paper[a] + (paper[a + 1] - paper[a]) * fx, low = paper[a + sw] + (paper[a + sw + 1] - paper[a + sw]) * fx
                    let bare = max(top + (low - top) * fy, 30)
                    let p = (y * w + x) * 4 + k
                    out[p] = UInt8(shape[min(4095, Int(Float(rgba[p]) / bare * 1.04 * 4095))] + 0.5)
                }
            }
        }
        return out
    }

    /// Where to trim a neighbouring page off the sides, as pixel columns. Trims only at the dark fold between pages, and
    /// only if printed lines lie beyond it and no yellow does, so notes in the margin stay.
    static func pageEdges(rgba: [UInt8], width w: Int, height h: Int, lines: [OCRLine]) -> (left: Int, right: Int) {
        var out = (left: 0, right: w)
        let wide = lines.filter { $0.words.count >= 5 }
        guard wide.count >= 10, w > 40, h > 40 else { return out }
        let W = Double(w)
        let a0 = median(wide.map { Double($0.box.minX) * W }), b0 = median(wide.map { Double($0.box.maxX) * W })
        let margin = (b0 - a0) * 0.01
        // brightness of each column, over the middle of the page, softened so one pen line doesn't count as a fold
        var level = [Double](repeating: 0, count: w)
        for y in stride(from: h / 10, to: h * 9 / 10, by: 4) {
            for x in 0..<w { let p = (y * w + x) * 4; level[x] += Double(rgba[p]) + Double(rgba[p + 1]) + Double(rgba[p + 2]) }
        }
        let r = max(4, w / 120)
        var sum = [Double](repeating: 0, count: w + 1)
        for x in 0..<w { sum[x + 1] = sum[x] + level[x] }
        let soft = (0..<w).map { x -> Double in let a = max(0, x - r), b = min(w, x + r + 1); return (sum[b] - sum[a]) / Double(b - a) }
        let paper = median(Array(soft[max(0, Int(a0))..<min(w, max(Int(a0) + 1, Int(b0)))]))
        func yellow(_ range: Range<Int>) -> Bool {
            var n = 0
            for y in stride(from: 0, to: h, by: 3) {
                for x in stride(from: range.lowerBound, to: range.upperBound, by: 3) {
                    let p = (y * w + x) * 4
                    let a = Int(rgba[p]), g = Int(rgba[p + 1]), b = Int(rgba[p + 2])
                    if a > 140, g > 128, b * 100 < 62 * min(a, g) { n += 1 }
                }
            }
            return n > 40
        }
        func spread(_ ls: [OCRLine]) -> Double { (ls.map { Double($0.box.midY) }.max() ?? 0) - (ls.map { Double($0.box.midY) }.min() ?? 0) }
        let beyondR = lines.filter { Double($0.box.minX) * W > b0 + margin * 2 }
        if beyondR.count >= 5, spread(beyondR) > 0.25, let near = beyondR.map({ Double($0.box.minX) * W }).min() {
            let a = Int(b0 + margin), b = min(w, Int(near))
            if a < b, let dark = (a..<b).min(by: { soft[$0] < soft[$1] }), soft[dark] < paper * 0.85 {
                // never through a note: past anything that starts before the fold and runs across it
                let across = lines.filter { Double($0.box.minX) * W < Double(dark) && Double($0.box.maxX) * W > Double(dark) }
                let cut = Int(across.map { Double($0.box.maxX) * W }.max() ?? Double(dark)) + 4
                if cut < b, !yellow(cut..<w) { out.right = cut }
            }
        }
        let beyondL = lines.filter { Double($0.box.maxX) * W < a0 - margin * 2 }
        if beyondL.count >= 5, spread(beyondL) > 0.25, let near = beyondL.map({ Double($0.box.maxX) * W }).max() {
            let a = max(0, Int(near)), b = Int(a0 - margin)
            if a < b, let dark = (a..<b).min(by: { soft[$0] < soft[$1] }), soft[dark] < paper * 0.85 {
                let across = lines.filter { Double($0.box.minX) * W < Double(dark) && Double($0.box.maxX) * W > Double(dark) }
                let cut = Int(across.map { Double($0.box.minX) * W }.min() ?? Double(dark)) - 4
                if cut > a, !yellow(0..<cut) { out.left = cut }
            }
        }
        return out
    }

    /// The same lines measured on the page after trimming. Anything left outside goes.
    static func trimmed(_ lines: [OCRLine], width w: Int, left: Int, right: Int) -> [OCRLine] {
        let a = CGFloat(left) / CGFloat(w), k = CGFloat(w) / CGFloat(max(right - left, 1))
        func moved(_ b: CGRect) -> CGRect { CGRect(x: (b.minX - a) * k, y: b.minY, width: b.width * k, height: b.height) }
        return lines.compactMap { l in
            let words = l.words.filter { $0.box.midX > a && ($0.box.midX - a) * k < 1 }.map { OCRWord(text: $0.text, box: moved($0.box)) }
            guard let first = words.first else { return nil }
            return OCRLine(text: words.map { $0.text }.joined(separator: " "), box: words.dropFirst().reduce(first.box) { $0.union($1.box) }, words: words, confidence: l.confidence)
        }
    }
}

/// Printed page numbers kept inside the PDF: one hidden marker per page, so a number stays with its page when
/// pages are added or moved, and survives every save. (Real PDF page labels can't be written with PDFKit.)
/// A marker is a 1-point, invisible square annotation, a type the notes code ignores.
enum PageLabels {
    static func isMarker(_ a: PDFAnnotation) -> Bool { BookPages.markerLabel(a.contents ?? "") != nil }
    static func marked(_ page: PDFPage) -> String? {
        for a in page.annotations {
            if let l = BookPages.markerLabel(a.contents ?? "") { return l }
        }
        return nil
    }
    /// The page number to cite: our marker, else the PDF's own page label, else the page's position.
    static func label(of page: PDFPage, index: Int) -> String {
        marked(page) ?? page.label.flatMap { $0.isEmpty ? nil : $0 } ?? String(index + 1)
    }
    static func isPhotoPage(_ page: PDFPage) -> Bool {
        page.annotations.contains { ($0.contents ?? "").hasPrefix(BookPages.photoMarkerPrefix) }
    }
    static func set(_ label: String, on page: PDFPage, photo: Bool) {
        for a in page.annotations where isMarker(a) { page.removeAnnotation(a) }
        let corner = page.bounds(for: .mediaBox).origin
        let a = PDFAnnotation(bounds: CGRect(origin: corner, size: CGSize(width: 1, height: 1)), forType: .square, withProperties: nil)
        a.contents = BookPages.markerText(label, photo: photo)
        a.color = .clear
        a.shouldDisplay = false
        a.shouldPrint = false
        page.addAnnotation(a)
    }
}

/// One photographed page, cleaned up and read.
struct PagePhoto {
    let source: URL
    let jpeg: Data
    let original: Data      // the page before whitening: what Claude reads, if you've added a key
    let lines: [OCRLine]
    let cropped: Bool
    var isbns: [String]
    var passages: [MarkedPassage] = []
    var text: String { lines.map { $0.text }.joined(separator: "\n") }
}

/// The optional Claude step. With an API key in Settings, each page photo is read by Claude for exact quotes,
/// handwriting, parentheses and page numbers. With no key, nothing leaves the Mac. The key is kept in a private file
/// rather than the Keychain, which would ask for permission again after every build.
enum ClaudeReader {
    static let model = "claude-sonnet-5-5"
    private static var keyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDF Search/claude-api-key")
    }
    static var key: String? {
        let k = (try? String(contentsOf: keyFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k ?? "").isEmpty ? nil : k
    }
    static func setKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let fm = FileManager.default
        if k.isEmpty { try? fm.removeItem(at: keyFile); return }
        try? fm.createDirectory(at: keyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? k.write(to: keyFile, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    }

    static func read(_ photo: PagePhoto, key: String, style: MarkingStyle) async -> ClaudePage? {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model, "max_tokens": 4000,
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": photo.original.base64EncodedString()]],
                ["type": "text", "text": ClaudeReading.prompt(style: style)]
            ] as [Any]]]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        for attempt in 0..<5 {
            var wait = attempt + 1
            if let got = try? await URLSession.shared.data(for: req), let answer = got.1 as? HTTPURLResponse {
                if answer.statusCode == 200 {
                    if let j = (try? JSONSerialization.jsonObject(with: got.0)) as? [String: Any],
                       let content = j["content"] as? [[String: Any]],
                       let page = ClaudeReading.parse(content.compactMap { $0["text"] as? String }.joined()) { return page }
                    problem = "its reply couldn't be understood"
                } else if answer.statusCode == 429 || answer.statusCode >= 500 {     // busy: wait and try again
                    problem = "the service was busy (\(answer.statusCode))"
                    wait = max((attempt + 1) * 8, Int(answer.value(forHTTPHeaderField: "retry-after") ?? "") ?? 0)
                } else {
                    problem = "the service said no (\(answer.statusCode))"
                    return nil
                }
            } else {
                problem = "no connection"
            }
            try? await Task.sleep(nanoseconds: UInt64(min(wait, 60)) * 1_000_000_000)
        }
        return nil
    }
    /// Why the last page failed, for the message when a batch ends.
    static var problem = ""
}

/// Everything that touches Apple's image and text recognition. All of it runs on this Mac.
enum BookPhotos {
    private static let context = CIContext()
    private static let longSide: CGFloat = 2400     // pixels kept per page
    private static let pageLongSide: CGFloat = 720  // points, so a page opens at about book size

    private static func zeroed(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }

    /// Reads one photo: one page, or two if it shows an open book. Empty if the file can't be read as a picture.
    static func read(_ url: URL, style: MarkingStyle) -> [PagePhoto] {
        guard let raw = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return [] }
        let image = zeroed(raw)
        let crop = pageCrop(image)
        let (page, lines) = upright(crop ?? image)
        let printed = barcodes(image)
        func photo(_ i: CIImage, _ l: [OCRLine]) -> PagePhoto? {
            // your marks are read from the straightened photo; the PDF gets the same page with whitened paper
            guard let page = straightened(i, l), let flat = picture(page.rgba, page.w, page.h),
                  let white = picture(PageFlattener.whiten(rgba: page.rgba, width: page.w, height: page.h), page.w, page.h),
                  let original = jpeg(CIImage(cgImage: flat)), let j = jpeg(CIImage(cgImage: white)) else { return nil }
            var found = printed
            for n in BookPages.isbns(in: page.lines.map { $0.text }.joined(separator: "\n")) where !found.contains(n) { found.append(n) }
            return PagePhoto(source: url, jpeg: j, original: original, lines: page.lines, cropped: crop != nil, isbns: found,
                             passages: marked(original, clean: j, page.lines, style))
        }
        // wider than tall: an open book, if both halves are full of text
        if page.extent.width > page.extent.height * 1.1 {
            let w = page.extent.width / 2, h = page.extent.height
            let left = zeroed(page.cropped(to: CGRect(x: 0, y: 0, width: w, height: h)))
            let right = zeroed(page.cropped(to: CGRect(x: w, y: 0, width: w, height: h)))
            let l = recognise(left), r = recognise(right)
            if characters(l) >= 200, characters(r) >= 200 {
                return [photo(left, l), photo(right, r)].compactMap { $0 }
            }
        }
        return photo(page, lines).map { [$0] } ?? []
    }

    /// Straightens a page by its lines of print and trims off any neighbouring page, then reads it again, so the words
    /// sit exactly where they now are. A page that wouldn't read as well straightened stays as it was.
    private static func straightened(_ image: CIImage, _ lines: [OCRLine]) -> (rgba: [UInt8], w: Int, h: Int, lines: [OCRLine])? {
        guard let master = jpeg(image, quality: 0.95), let px = pixels(master) else { return nil }
        var rgba = px.rgba, read = lines
        let w = px.w, h = px.h
        let wanted = UserDefaults.standard.object(forKey: "straightenPages") as? Bool ?? true
        if wanted, let model = PageFlattener.fit(lines, width: w, height: h) {
            let flat = PageFlattener.flatten(rgba: rgba, width: w, height: h, model)
            if let shown = picture(flat, w, h) {
                let again = recognise(CIImage(cgImage: shown))
                if BookPages.readingScore(again) >= BookPages.readingScore(lines) * 0.9 { rgba = flat; read = again }
            }
        }
        let keep = PageFlattener.pageEdges(rgba: rgba, width: w, height: h, lines: read)
        guard keep.left > 0 || keep.right < w else { return (rgba, w, h, read) }
        let width = keep.right - keep.left
        var cut = [UInt8](repeating: 255, count: width * h * 4)
        for y in 0..<h {
            let from = (y * w + keep.left) * 4
            cut.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: rgba[from..<(from + width * 4)])
        }
        return (cut, width, h, PageFlattener.trimmed(read, width: w, left: keep.left, right: keep.right))
    }

    private static func picture(_ rgba: [UInt8], _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData), let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// The passages marked on a page of text, going by how this person marks their books.
    /// Yellow is read from the photo; pen parentheses from the whitened page, where they're clearest.
    private static func marked(_ jpeg: Data, clean: Data, _ lines: [OCRLine], _ style: MarkingStyle) -> [MarkedPassage] {
        guard lines.count >= 8 else { return [] }
        let passages = style.marginStreaks ? pixels(jpeg).map { BookMarks.passages(rgba: $0.rgba, width: $0.w, height: $0.h, lines: lines, underlines: style.underlines) } ?? [] : []
        let terms = style.parenthesisTags ? pixels(clean).map { BookMarks.keyTerms(rgba: $0.rgba, width: $0.w, height: $0.h, lines: lines) } ?? [] : []
        return BookMarks.attach(terms, to: passages)
    }

    private static func pixels(_ jpeg: Data) -> (rgba: [UInt8], w: Int, h: Int)? {
        guard let source = CGDataProvider(data: jpeg as CFData),
              let picture = CGImage(jpegDataProviderSource: source, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let w = picture.width, h = picture.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let c = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? (rgba, w, h) : nil
    }

    /// Writes marked passages onto a PDF page as Interesting highlights, one per passage, flagged to be checked.
    static func highlight(_ passages: [MarkedPassage], on page: PDFPage) {
        let size = page.bounds(for: .mediaBox).size
        for p in passages {
            let rects = p.boxes.map { CGRect(x: $0.minX * size.width, y: $0.minY * size.height,
                                             width: $0.width * size.width, height: $0.height * size.height) }
            guard let first = rects.first else { continue }
            let box = rects.dropFirst().reduce(first) { $0.union($1) }
            let a = PDFAnnotation(bounds: box, forType: .highlight, withProperties: nil)
            a.color = HighlightLevel.interesting.nsColor
            a.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - box.minX, x1 = r.maxX - box.minX
                let y0 = r.minY - box.minY, y1 = r.maxY - box.minY
                return [NSValue(point: NSPoint(x: x0, y: y1)), NSValue(point: NSPoint(x: x1, y: y1)),
                        NSValue(point: NSPoint(x: x0, y: y0)), NSValue(point: NSPoint(x: x1, y: y0))]
            }
            let note = BookMarks.joinContents(note: BookMarks.comment(p), quote: p.corrected)
            if !note.isEmpty { a.contents = note }
            a.userName = NSFullUserName()
            a.modificationDate = Date()
            page.addAnnotation(a)
        }
    }

    private static func characters(_ lines: [OCRLine]) -> Int { lines.reduce(0) { $0 + $1.text.count } }

    /// Finds the page in the photo and squares it up. nil if no clear page is found (the whole photo is used).
    private static func pageCrop(_ image: CIImage) -> CIImage? {
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        guard let r = request.results?.first, r.confidence > 0.5 else { return nil }
        let share = BookPages.area([r.topLeft, r.topRight, r.bottomRight, r.bottomLeft])
        guard share > 0.2, share < 0.995 else { return nil }
        let size = image.extent.size
        // the shape found can cut across a curled corner, so it's opened out a little
        let cx = (r.topLeft.x + r.topRight.x + r.bottomLeft.x + r.bottomRight.x) / 4
        let cy = (r.topLeft.y + r.topRight.y + r.bottomLeft.y + r.bottomRight.y) / 4
        func v(_ p: CGPoint) -> CIVector {
            CIVector(x: min(1, max(0, cx + (p.x - cx) * 1.06)) * size.width, y: min(1, max(0, cy + (p.y - cy) * 1.06)) * size.height)
        }
        let out = image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": v(r.topLeft), "inputTopRight": v(r.topRight),
            "inputBottomRight": v(r.bottomRight), "inputBottomLeft": v(r.bottomLeft)])
        return out.extent.isInfinite || out.extent.isEmpty ? nil : zeroed(out)
    }

    /// Turns the page the right way up and reads it. A phone held flat saves pictures any way round, and the saved
    /// orientation can't be trusted, so a small copy is read all four ways round.
    private static func upright(_ image: CIImage) -> (CIImage, [OCRLine]) {
        let small = smallCopy(image)
        // Vision reads sideways print almost as well as upright print, so the ink decides first
        if let quarter = BookPages.turnFromInk(inkReadings(small)) {
            let turned = zeroed(image.oriented(quarters[quarter]))
            return (turned, recognise(turned))
        }
        let turns: [CGImagePropertyOrientation] = [.up, .right, .left, .down]
        let turn = BookPages.bestTurn(turns.map { BookPages.readingScore(recognise(zeroed(small.oriented($0)))) })
        let turned = turn == 0 ? image : zeroed(image.oriented(turns[turn]))
        return (turned, recognise(turned))
    }

    private static let quarters: [CGImagePropertyOrientation] = [.up, .right, .down, .left]

    private static func smallCopy(_ image: CIImage) -> CIImage {
        let scale = min(1, 1400 / max(image.extent.width, image.extent.height, 1))
        return zeroed(image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)))
    }

    private static func inkReadings(_ small: CIImage) -> [BookPages.InkReading] {
        quarters.compactMap { q in
            jpeg(zeroed(small.oriented(q)), quality: 0.9).flatMap(pixels).map { BookPages.inkReading(rgba: $0.rgba, width: $0.w, height: $0.h) }
        }
    }

    private static func recognise(_ image: CIImage) -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        var out: [OCRLine] = []
        for o in request.results ?? [] {
            guard let t = o.topCandidates(1).first else { continue }
            let s = t.string
            let ranges = BookPages.wordRanges(s)
            let boxes = ranges.map { r in (try? t.boundingBox(for: r))?.boundingBox }
            // Vision sometimes gives every word the whole line's box
            let good = !boxes.contains { $0 == nil }
                && !(ranges.count >= 3 && boxes.contains { ($0?.width ?? 0) > o.boundingBox.width * 0.9 })
            let words = good ? zip(ranges, boxes).map { OCRWord(text: String(s[$0]), box: $1 ?? o.boundingBox) }
                             : BookPages.spread(ranges.map { String(s[$0]) }, across: o.boundingBox)
            out.append(OCRLine(text: s, box: o.boundingBox, words: words, confidence: t.confidence))
        }
        return out
    }

    /// An ISBN from a barcode (a back cover), if the photo shows one.
    private static func barcodes(_ image: CIImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.ean13]
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.payloadStringValue }.compactMap(BookPages.isbn13)
    }

    private static func jpeg(_ image: CIImage, quality level: CGFloat = 0.72) -> Data? {
        let long = max(image.extent.width, image.extent.height)
        let s = min(1, longSide / max(long, 1))
        let scaled = zeroed(image.transformed(by: CGAffineTransform(scaleX: s, y: s)))
        let box = CGRect(origin: .zero, size: CGSize(width: floor(scaled.extent.width), height: floor(scaled.extent.height)))
        guard box.width >= 1, box.height >= 1, let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: scaled.cropped(to: box), colorSpace: sRGB, options: [quality: level])
    }

    /// A one-page PDF: the words first, then the picture on top of them. The words can't be seen, but search,
    /// selection and highlighting all use them.
    static func pageData(_ p: PagePhoto) -> Data? {
        guard let source = CGDataProvider(data: p.jpeg as CFData),
              let picture = CGImage(jpegDataProviderSource: source, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let px = CGSize(width: picture.width, height: picture.height)
        let k = pageLongSide / max(px.width, px.height)
        var box = CGRect(x: 0, y: 0, width: px.width * k, height: px.height * k)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let c = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        c.beginPDFPage(nil)
        for line in p.lines {
            for w in line.words {
                let r = CGRect(x: w.box.minX * box.width, y: w.box.minY * box.height,
                               width: w.box.width * box.width, height: w.box.height * box.height)
                guard r.width > 0, r.height > 0 else { continue }
                func typeset(_ text: String, size: CGFloat) -> CTLine {
                    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
                    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]) as CFAttributedString)
                }
                // sized to fit the word's width: stretching the text instead breaks words into s p a c e d letters
                let natural = r.height * 0.9
                let width = CTLineGetTypographicBounds(typeset(w.text, size: natural), nil, nil, nil)
                guard width > 0 else { continue }
                c.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.2)
                CTLineDraw(typeset(w.text + " ", size: natural * r.width / CGFloat(width)), c)     // the space keeps words apart in copied text
            }
        }
        c.draw(picture, in: box)
        c.endPDFPage()
        c.closePDF()
        return data as Data
    }

    /// Adds pages to a book's PDF (making it if needed), each where its page number says it goes. A page already
    /// there is replaced by a new photo of it, unless it has highlights, when the new one goes next to it.
    /// Returns where the first new page is and how many went in, or nil if the PDF couldn't be written.
    static func add(_ pages: [(photo: PagePhoto, label: String)], to url: URL) -> (first: Int, placed: Int)? {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let opened = exists ? PDFDocument(url: url) : PDFDocument()
        guard let doc = opened, !doc.isLocked else { return nil }
        var held: [PDFDocument] = []          // a page needs its own document alive until the save
        var first: Int?
        var placed = 0
        var previous: Double?
        var unknowns = 0.0
        for (photo, label) in pages {
            guard let data = pageData(photo), let single = PDFDocument(data: data), let page = single.page(at: 0) else { continue }
            held.append(single)
            var at: Int?
            if label != BookPages.noNumber && label != BookPages.front {
                for i in 0..<doc.pageCount {
                    guard let old = doc.page(at: i), PageLabels.marked(old) == label else { continue }
                    if old.annotations.contains(where: Marginalia.isMarkup) { at = i + 1 } else { doc.removePage(at: i); at = i }
                    break
                }
            }
            if at == nil {
                let rank: Double
                if let r = BookPages.rank(label) { rank = r; unknowns = 0 } else { unknowns += 0.001; rank = (previous ?? .greatestFiniteMagnitude) + unknowns }
                let ranks = (0..<doc.pageCount).map { i in doc.page(at: i).flatMap(PageLabels.marked).flatMap(BookPages.rank) }
                at = BookPages.insertionIndex(rank: rank, among: ranks)
            }
            guard let index = at else { continue }
            doc.insert(page, at: index)
            if let placed = doc.page(at: index) {
                PageLabels.set(label, on: placed, photo: true)
                highlight(photo.passages, on: placed)
            }
            if let r = BookPages.rank(label) { previous = r }
            first = min(first ?? index, index)
            placed += 1
        }
        guard let start = first else { return nil }
        keepSummaryOnFirstPage(doc)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).pdfsearch-saving")
        guard withExtendedLifetime(held, { doc.write(to: tmp) }) else { try? fm.removeItem(at: tmp); return nil }
        do {
            if exists { _ = try fm.replaceItemAt(url, withItemAt: tmp) } else { try fm.moveItem(at: tmp, to: url) }
        } catch {
            try? fm.removeItem(at: tmp)
            return nil
        }
        return (start, placed)
    }

    /// "About this paper" is read from page 1, so it has to stay there when a page goes in front of it.
    static func keepSummaryOnFirstPage(_ doc: PDFDocument) {
        guard doc.pageCount > 1, let top = doc.page(at: 0) else { return }
        for i in 1..<doc.pageCount {
            guard let p = doc.page(at: i) else { continue }
            for a in p.annotations where Marginalia.isSummary(a) { p.removeAnnotation(a); top.addAnnotation(a) }
        }
    }

    /// Moves a photo into a folder, never over another file. False if it couldn't be moved.
    static func move(_ url: URL, into folder: String) -> Bool {
        let fm = FileManager.default
        guard (try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil else { return false }
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var dest = URL(fileURLWithPath: folder).appendingPathComponent(url.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = URL(fileURLWithPath: folder).appendingPathComponent("\(stem) \(n).\(ext)")
            n += 1
        }
        return (try? fm.moveItem(at: url, to: dest)) != nil
    }

    static func hasCover(_ url: URL) -> Bool {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return false }
        return PageLabels.marked(page) == BookPages.cover
    }
    /// A PDF made from photos, which can grow, rather than a full book or chapter, which is left alone.
    static func isPhotoBook(_ url: URL) -> Bool {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0, let page = doc.page(at: 0) else { return false }
        return PageLabels.isPhotoPage(page)
    }
}

extension Library {
    static let photoTypes: Set<String> = ["jpg", "jpeg", "heic", "heif", "png", "tif", "tiff"]
    static func isPhoto(_ url: URL) -> Bool { photoTypes.contains(url.pathExtension.lowercased()) }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add"
        panel.message = "Choose photos of book pages. Include the copyright page for a new book."
        if panel.runModal() == .OK { addPhotos(panel.urls) }
    }

    /// The one place to put photos of book pages. PDF Search empties it whenever it comes to the front:
    /// filed photos go to Done/<key>, photos it couldn't file go to Not Filed/<key> (or the ISBN, or
    /// "Unknown book <date>"). Your originals are never deleted.
    static var photoInbox: String { Paths.papers + "/Book Photos" }

    func openPhotoInbox() {
        try? FileManager.default.createDirectory(atPath: Library.photoInbox, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: Library.photoInbox, isDirectory: true))
    }

    /// Photos waiting in the inbox, with their sizes.
    private func inboxPhotos() -> [URL: Int] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: Library.photoInbox, isDirectory: true),
                                                                  includingPropertiesForKeys: keys, options: .skipsHiddenFiles)) ?? []
        var out: [URL: Int] = [:]
        for u in items where Library.isPhoto(u) && !photoQueued.contains(u.path) {
            guard let v = try? u.resourceValues(forKeys: Set(keys)), let size = v.fileSize, size > 0 else { continue }
            // Finder dates a file 1984 while it's still copying
            if let d = v.contentModificationDate, d.timeIntervalSince1970 < 473_385_600 { continue }
            out[u] = size
        }
        return out
    }

    /// Looks in the inbox (when the app comes to the front). A photo is taken once its size has stopped
    /// changing, so one still being copied waits.
    func checkPhotoInbox() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.papers) else { return }     // the stick isn't plugged in
        try? fm.createDirectory(atPath: Library.photoInbox, withIntermediateDirectories: true)
        let first = inboxPhotos()
        guard !first.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let second = self.inboxPhotos()
            let ready = second.filter { first[$0.key] == $0.value }.map { $0.key }
            if !ready.isEmpty { self.addPhotos(ready) }
            if ready.count < second.count { self.checkPhotoInbox() }
        }
    }

    /// Finds citation details for imported PDFs in the background, with no cards. Only details that match the PDF
    /// are kept; anything else stays searchable with no entry. `inPlace` leaves files where they are (a folder you
    /// added); otherwise each is copied into Papers/Library and your original stays put.
    func lookUpDetails(_ urls: [URL], inPlace: Bool) {
        let before = photoTask
        photoTask = Task { @MainActor in
            await before?.value
            let wanted = urls.filter { bib.entry(forPath: $0.standardizedFileURL.path) == nil }
            guard !wanted.isEmpty else { return }
            var found = 0
            for (i, u) in wanted.enumerated() {
                showFlash("Looking up details: \(i + 1) of \(wanted.count)…", seconds: 60)
                if let m = await details(for: u) {
                    let key = m.key(existing: bib.libraryKeys)
                    if addToLibrary(type: m.kind.bibType, key: key, fields: m.fields, file: u, move: false, inPlace: inPlace, quiet: true) { found += 1 }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)     // be gentle with the lookup services
            }
            reloadBib(force: true)
            refresh()
            let missed = wanted.count - found
            showFlash("Found details for \(found) of \(wanted.count) PDFs." + (missed == 0 ? "" : " To fix the rest, right-click ▸ Look Up Citation Details…"), seconds: 15)
        }
    }

    @MainActor
    private func details(for url: URL) async -> AddPaperModel? {
        let m = AddPaperModel(file: url)
        await m.start()
        guard !m.title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if !m.isbn.isEmpty && m.doi.isEmpty { return m }     // a book, found by its ISBN (checked by its check digit)
        let front = await Task.detached(priority: .utility) { () -> String in
            guard let doc = PDFDocument(url: url) else { return "" }
            return (0..<min(8, doc.pageCount)).compactMap { doc.page(at: $0)?.string }.joined(separator: "\n")
        }.value
        return BookPages.titleAppears(m.title, in: front) ? m : nil
    }

    /// Turns photos into book pages. Batches run one after another, in the background.
    func addPhotos(_ urls: [URL]) {
        let fresh = urls.filter { !photoQueued.contains($0.path) }
        guard !fresh.isEmpty else { return }
        photoQueued.formUnion(fresh.map { $0.path })
        let before = photoTask
        photoTask = Task { @MainActor in
            await before?.value
            await importPhotos(fresh)
        }
    }

    @MainActor
    private func importPhotos(_ urls: [URL]) async {
        // right after launch the bibliography may not be loaded yet, and a known book would look new
        var waited = 0
        while bib.entries.isEmpty, waited < 50, FileManager.default.fileExists(atPath: Paths.libraryBib) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        if bib.entries.isEmpty, FileManager.default.fileExists(atPath: Paths.libraryBib) {
            photoQueued.subtract(urls.map { $0.path })
            showFlash("Couldn't read library.bib, so the photos weren't filed.", seconds: 15)
            return
        }
        Viewer.current?.flushSave()
        let style = MarkingStyle.load(from: Library.photoInbox)
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var photos: [PagePhoto] = []
        var unreadable: [URL] = []
        var read = [[PagePhoto]](repeating: [], count: sorted.count)
        showFlash("Reading photo 1 of \(sorted.count)…", seconds: 120)
        await withTaskGroup(of: (Int, [PagePhoto]).self) { group -> Void in     // four photos at a time, kept in order
            var next = 0, finished = 0
            while next < min(4, sorted.count) {
                let i = next, u = sorted[i]
                next += 1
                group.addTask(priority: .userInitiated) { (i, BookPhotos.read(u, style: style)) }
            }
            while let done = await group.next() {
                read[done.0] = done.1
                finished += 1
                showFlash("Reading photo \(min(finished + 1, sorted.count)) of \(sorted.count)…", seconds: 120)
                if next < sorted.count {
                    let i = next, u = sorted[i]
                    next += 1
                    group.addTask(priority: .userInitiated) { (i, BookPhotos.read(u, style: style)) }
                }
            }
        }
        for (i, u) in sorted.enumerated() {
            if read[i].isEmpty { unreadable.append(u) }
            photos += read[i]
        }
        var numbers = photos.map { BookPages.printedNumber($0.lines, cropped: $0.cropped, handwritten: style.handwrittenPageNumbers) }
        var unread = 0
        if let key = ClaudeReader.key {
            let wanted = photos.indices.filter { photos[$0].lines.count >= 8 }
            var finished = 0
            var missed: [Int] = []
            for batch in stride(from: 0, to: wanted.count, by: 8) {     // eight pages at a time
                showFlash("Claude is reading page \(min(finished + 1, wanted.count)) of \(wanted.count)…", seconds: 180)
                let some = wanted[batch..<min(batch + 8, wanted.count)]
                let answers = await withTaskGroup(of: (Int, ClaudePage?).self) { group -> [(Int, ClaudePage?)] in
                    for i in some { let p = photos[i]; group.addTask { (i, await ClaudeReader.read(p, key: key, style: style)) } }
                    var all: [(Int, ClaudePage?)] = []
                    for await a in group { all.append(a) }
                    return all
                }
                for (i, answer) in answers {
                    finished += 1
                    guard let page = answer else { missed.append(i); continue }
                    photos[i].passages = ClaudeReading.apply(page, to: photos[i].passages, lines: photos[i].lines)
                    if let n = page.number { numbers[i] = n }
                }
            }
            // anything that failed in the rush gets a turn of its own
            for i in missed.sorted() {
                showFlash("Claude is rereading a page…", seconds: 180)
                guard let page = await ClaudeReader.read(photos[i], key: key, style: style) else { unread += 1; continue }
                photos[i].passages = ClaudeReading.apply(page, to: photos[i].passages, lines: photos[i].lines)
                if let n = page.number { numbers[i] = n }
            }
        }
        // an ISBN on a numbered page is another book being mentioned, not this one's
        for i in photos.indices where numbers[i] != nil { photos[i].isbns = [] }
        let shots = photos.indices.map { (isbns: photos[$0].isbns, numbered: numbers[$0] != nil) }
        var messages: [String] = []
        var outcome: [URL: (folder: String, filed: Bool)] = [:]     // where each photo goes next
        for group in BookPages.groups(shots) {
            let pages = group.map { photos[$0] }
            let done = await fileBook(pages, numbers: group.map { numbers[$0] })
            messages.append(done.message)
            for p in pages where outcome[p.source]?.filed != true { outcome[p.source] = (done.folder, done.filed) }
        }
        if !unreadable.isEmpty { messages.append("\(unreadable.count) file\(unreadable.count == 1 ? "" : "s") couldn't be read as a photo.") }
        if unread > 0 { messages.append("Claude couldn't read \(unread) page\(unread == 1 ? "" : "s"), so they use the Mac's reading: \(ClaudeReader.problem).") }
        // empty the inbox into a folder named for the book; a photo that can't be moved stays queued, so it
        // isn't read again and again
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let nameless = "Unknown book " + f.string(from: Date())
        var parked = Set<String>()
        for u in urls {
            let inInbox = u.deletingLastPathComponent().path == URL(fileURLWithPath: Library.photoInbox).path
            guard inInbox else { photoQueued.remove(u.path); continue }
            let filed = outcome[u]?.filed == true
            let name = (outcome[u]?.folder).flatMap { $0.isEmpty ? nil : $0 } ?? nameless
            if !filed { parked.insert(name) }
            if BookPhotos.move(u, into: Library.photoInbox + (filed ? "/Done/" : "/Not Filed/") + name) { photoQueued.remove(u.path) }
        }
        if !parked.isEmpty { messages.append("Not filed: see Book Photos/Not Filed/" + parked.sorted().joined(separator: ", ") + ".") }
        showFlash(messages.joined(separator: " "), seconds: 20)
    }

    /// What's known about the book in a batch: an entry already in library.bib, or the details of a new one.
    private enum Book { case known(BibEntry), new(type: String, key: String, fields: [String: String]), unknown(String) }

    @MainActor
    private func identify(_ photos: [PagePhoto]) async -> Book {
        let books = bib.entries.filter { $0.inLibrary && $0.type == "book" }
        var wanted: [String] = []
        for p in photos { for i in p.isbns where !wanted.contains(i) { wanted.append(i) } }
        for i in wanted {
            if let e = books.first(where: { BookPages.isbnList($0.fields["isbn"] ?? "").contains(i) }) { return .known(e) }
        }
        for i in wanted {
            guard let b = await Lookup.book(isbn: i) else { continue }
            let title = Lookup.clean(b.title)
            let names = b.authors.map(Lookup.lastFirst)
            let last = names.first.map(BibEntry.lastName) ?? ""
            let same = books.first { e in
                BookPages.shortTitle(e.title) == BookPages.shortTitle(title)
                    && (last.isEmpty || e.people.contains { BibIndex.fold(BibEntry.lastName($0)) == BibIndex.fold(last) })
                    && (e.fields["isbn"] == nil || e.year == b.year)      // a different edition has different pages
            }
            if let e = same { return .known(e) }
            var f: [String: String] = ["title": title, "year": b.year, "publisher": b.publisher, "address": b.place, "isbn": i]
            if !names.isEmpty { f["author"] = names.joined(separator: " and ") }
            let key = CiteKey.make(lastName: last, year: b.year, title: title, existing: bib.libraryKeys)
            return .new(type: "book", key: key, fields: f.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty })
        }
        if !wanted.isEmpty { return .unknown("No details found online for ISBN \(wanted[0]).") }
        let heads = photos.map { BookPages.runningHeads($0.lines, cropped: $0.cropped) }
        if let key = BookPages.bookForHeads(heads, books: books.map { (key: $0.key, title: $0.title) }),
           let e = books.first(where: { $0.key == key }) { return .known(e) }
        return .unknown("No ISBN, and the page headers didn't match a book in your library.")
    }

    /// Files one book's photos, and says what happened and whether they were filed.
    @MainActor
    private func fileBook(_ photos: [PagePhoto], numbers: [String?]) async -> (message: String, filed: Bool, folder: String) {
        showFlash("Finding the book…", seconds: 120)
        let book = await identify(photos)
        let fm = FileManager.default
        func labelled(cover has: Bool) -> [(photo: PagePhoto, label: String)] {
            let labels = BookPages.labels(numbers: numbers, isbnPage: photos.map { !$0.isbns.isEmpty },
                                          characters: photos.map { $0.text.count }, hasCover: has)
            return Array(zip(photos, labels)).map { (photo: $0.0, label: $0.1) }
        }
        func place(_ pages: [(photo: PagePhoto, label: String)], in url: URL) async -> (first: Int, placed: Int)? {
            await Task.detached(priority: .userInitiated) { BookPhotos.add(pages, to: url) }.value
        }
        // so highlights reach the paper note and My Notes straight away
        func mirror(_ path: String) {
            guard photos.contains(where: { !$0.passages.isEmpty }), let doc = PDFDocument(url: URL(fileURLWithPath: path)) else { return }
            afterSave(path: path, notes: Marginalia.collect(doc), summary: Marginalia.summary(doc))
        }
        func summary(_ pages: [(photo: PagePhoto, label: String)], placed: Int, _ key: String) -> String {
            let blank = pages.filter { $0.label == BookPages.noNumber }.count
            let note = blank == 0 ? "" : " \(blank) with no readable page number (cited as p. ?; fix with File ▸ Set Printed Page Number…)."
            let lost = pages.count - placed
            let failed = lost == 0 ? "" : " \(lost) couldn't be added."
            let marked = photos.reduce(0) { $0 + $1.passages.count }
            let found = marked == 0 ? "" : " \(marked) marked passage\(marked == 1 ? "" : "s") highlighted."
            return "Added \(placed) page\(placed == 1 ? "" : "s") to @\(key).\(found)\(note)\(failed)"
        }
        switch book {
        case .unknown(let why):
            let isbn = photos.lazy.flatMap({ $0.isbns }).first
            return (why + " Nothing was filed. Add a photo of the book's copyright page and try again.", false, isbn.map { "ISBN " + $0 } ?? "")
        case .known(let e):
            let dest = URL(fileURLWithPath: Paths.libraryFolder + "/" + e.key + ".pdf")
            let own = e.file.map { URL(fileURLWithPath: $0) } ?? dest
            if fm.fileExists(atPath: own.path), !BookPhotos.isPhotoBook(own) {
                return ("You already have @\(e.key) as a PDF, so these photos were not added to it.", false, e.key)
            }
            do { try fm.createDirectory(at: own.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { return ("Couldn't save the pages: \(error.localizedDescription)", false, e.key) }
            // this PDF may be open: save it and close it, so nothing can write the old copy back over the new one
            if Viewer.current?.path == own.path { Viewer.current?.close() } else { Viewer.current?.flushSave() }
            let pages = labelled(cover: BookPhotos.hasCover(own))
            guard let done = await place(pages, in: own) else { return ("Couldn't save the pages to @\(e.key).", false, e.key) }
            refresh()
            mirror(own.path)
            openPage(own.path, done.first)
            return (summary(pages, placed: done.placed, e.key), true, e.key)
        case .new(let type, let key, let fields):
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".pdf")
            let pages = labelled(cover: false)
            guard let done = await place(pages, in: tmp) else { return ("Couldn't make a PDF for @\(key).", false, key) }
            guard addToLibrary(type: type, key: key, fields: fields, file: tmp, move: true) else { return ("Couldn't add @\(key).", false, key) }
            mirror(Paths.libraryFolder + "/" + key + ".pdf")
            return (summary(pages, placed: done.placed, key), true, key)
        }
    }

    private func openPage(_ path: String, _ index: Int) {
        linkRequest = LinkRequest(path: path, page: index + 1, n: (linkRequest?.n ?? 0) + 1)
    }
}

// MARK: - SQLite (full-text index)

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private let PAGE_SLOTS = 100_000  // fts rowid = fileID * PAGE_SLOTS + page  (page 0 = file name)
private let NOTE_SLOTS = 10_000   // notes rowid = fileID * NOTE_SLOTS + n (PDF notes), or negative for your Markdown notes

/// A note that matched a search (see DB.searchNotes).
struct NoteRow {
    let rowid: Int
    let filePath: String        // the PDF ("h", "s")
    let notePath: String        // the .md file ("o")
    let pdf: String             // "o": its frontmatter pdf (relative to Papers, as written)
    let key: String             // "o": its citekey or file name
    let kind: String
    let page: Int
    let label: String
    let quote: String
    let comment: String
    let quoteHL: String         // snippets with \u{2}…\u{3} around matches
    let commentHL: String
    let score: Double
}

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
            CREATE VIRTUAL TABLE IF NOT EXISTS notes USING fts5(quote, comment, kind UNINDEXED, page UNINDEXED,
                                                                label UNINDEXED, tokenize = 'unicode61 remove_diacritics 2');
            CREATE TABLE IF NOT EXISTS notefiles(id INTEGER PRIMARY KEY, path TEXT UNIQUE NOT NULL,
                                                 mtime REAL, pdf TEXT, key TEXT);
            """)
        exec("ALTER TABLE folders ADD COLUMN name TEXT")  // older indexes; harmless if it already exists
        // Recently Edited: newest highlight/note date found in the PDF, and the time of each save made here
        exec("ALTER TABLE files ADD COLUMN edited REAL")
        exec("CREATE TABLE IF NOT EXISTS edits(path TEXT PRIMARY KEY, time REAL)")
        // Recently Added: when each file first arrived. Its own table, because `store` replaces a file's row on every re-read.
        exec("CREATE TABLE IF NOT EXISTS added(path TEXT PRIMARY KEY, time REAL)")
        // Index version 2 adds My Notes: read every PDF once more so its highlights and notes are indexed too.
        var version = 0
        if let st = prepare("PRAGMA user_version"), st.step() { version = st.int(0) }
        if ok && version < 2 {
            exec("UPDATE files SET mtime = 0")
            exec("PRAGMA user_version = 2")
        }
        // Index version 3: files already here are dated by when the file was created; new ones by when they arrive.
        if ok && version < 3 {
            var paths: [String] = []
            if let st = prepare("SELECT path FROM files") { while st.step() { paths.append(st.text(0)) } }
            exec("BEGIN")
            for p in paths {
                let d = (try? FileManager.default.attributesOfItem(atPath: p))?[.creationDate] as? Date
                run("INSERT OR IGNORE INTO added(path, time) VALUES (?,?)", [p, d?.timeIntervalSince1970 ?? 0])
            }
            exec("COMMIT")
            exec("PRAGMA user_version = 3")
        }
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

    func store(path: String, mtime: Double, size: Int, pages: [String]?, notes: [IndexedNote] = [], edited: Double? = nil) {
        exec("BEGIN")
        if let old = prepare("SELECT id FROM files WHERE path=?", [path]), old.step() {
            removeFile(id: old.int(0))
        }
        let chars = pages?.reduce(0) { $0 + $1.utf16.count } ?? 0
        run("INSERT INTO files(path, mtime, size, npages, chars, edited) VALUES (?,?,?,?,?,?)",
            [path, mtime, size, pages?.count ?? -1, chars, edited])
        run("INSERT OR IGNORE INTO added(path, time) VALUES (?,?)", [path, Date().timeIntervalSince1970])
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
        if !notes.isEmpty, let ins = prepare("INSERT INTO notes(rowid, quote, comment, kind, page, label) VALUES (?,?,?,?,?,?)") {
            for (i, n) in notes.enumerated() where i + 1 < NOTE_SLOTS {
                ins.bind([id * NOTE_SLOTS + i + 1, n.quote, n.comment, n.kind, n.page, n.label]); ins.step(); ins.reset()
            }
        }
        exec("COMMIT")
    }

    func removeFile(id: Int) {
        run("DELETE FROM fts WHERE rowid BETWEEN ? AND ?", [id * PAGE_SLOTS, id * PAGE_SLOTS + PAGE_SLOTS - 1])
        run("DELETE FROM notes WHERE rowid BETWEEN ? AND ?", [id * NOTE_SLOTS, id * NOTE_SLOTS + NOTE_SLOTS - 1])
        run("DELETE FROM files WHERE id=?", [id])
    }

    // your own writing in the paper notes (rowid = -(notefile id × NOTE_SLOTS + paragraph number))

    func noteFiles() -> [String: (id: Int, mtime: Double)] {
        var out: [String: (id: Int, mtime: Double)] = [:]
        guard let st = prepare("SELECT id, path, mtime FROM notefiles") else { return out }
        while st.step() { out[st.text(1)] = (st.int(0), st.double(2)) }
        return out
    }

    func ownParagraphs(noteFileID id: Int) -> [String] {
        var out: [String] = []
        guard let st = prepare("SELECT comment FROM notes WHERE rowid BETWEEN ? AND ? ORDER BY rowid DESC",
                               [-(id * NOTE_SLOTS + NOTE_SLOTS - 1), -(id * NOTE_SLOTS)]) else { return out }
        while st.step() { out.append(st.text(0)) }
        return out
    }

    func storeNoteFile(path: String, mtime: Double, pdf: String, key: String, paragraphs: [String]) {
        exec("BEGIN")
        var id = 0
        if let st = prepare("SELECT id FROM notefiles WHERE path=?", [path]), st.step() { id = st.int(0) }
        if id > 0 {
            run("DELETE FROM notes WHERE rowid BETWEEN ? AND ?", [-(id * NOTE_SLOTS + NOTE_SLOTS - 1), -(id * NOTE_SLOTS)])
            run("UPDATE notefiles SET mtime=?, pdf=?, key=? WHERE id=?", [mtime, pdf, key, id])
        } else {
            run("INSERT INTO notefiles(path, mtime, pdf, key) VALUES (?,?,?,?)", [path, mtime, pdf, key])
            id = Int(sqlite3_last_insert_rowid(db))
        }
        if !paragraphs.isEmpty, let ins = prepare("INSERT INTO notes(rowid, quote, comment, kind, page, label) VALUES (?,?,?,?,?,?)") {
            for (i, p) in paragraphs.enumerated() where i + 1 < NOTE_SLOTS {
                ins.bind([-(id * NOTE_SLOTS + i + 1), "", p, "o", 0, ""]); ins.step(); ins.reset()
            }
        }
        exec("COMMIT")
    }

    func removeNoteFile(id: Int) {
        exec("BEGIN")
        run("DELETE FROM notes WHERE rowid BETWEEN ? AND ?", [-(id * NOTE_SLOTS + NOTE_SLOTS - 1), -(id * NOTE_SLOTS)])
        run("DELETE FROM notefiles WHERE id=?", [id])
        exec("COMMIT")
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
        exec("DELETE FROM fts; DELETE FROM notes; DELETE FROM notefiles; DELETE FROM edits; DELETE FROM files; DELETE FROM folders; DELETE FROM excluded; VACUUM;")
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

    /// PDFs containing every term, each anywhere in the PDF. Results show the pages holding any of them.
    func search(all parts: [String], scope: String?) -> [Hit] {
        guard let first = parts.first else { return [] }
        if parts.count == 1 { return search(first, scope: scope) }
        let f = scopeFilter(scope)
        var both: Set<Int>?
        for p in parts {
            guard let st = prepare("""
                SELECT DISTINCT fts.rowid / \(PAGE_SLOTS)
                FROM fts JOIN files ON files.id = fts.rowid / \(PAGE_SLOTS)
                WHERE fts MATCH ?\(f.sql)
                """, ([p] as [Any?]) + f.args) else { return [] }
            var found = Set<Int>()
            while st.step() { found.insert(st.int(0)) }
            both = both.map { $0.intersection(found) } ?? found
            if both?.isEmpty == true { return [] }
        }
        return search(parts.joined(separator: " OR "), scope: scope, only: both)
    }

    func search(_ query: String, scope: String?, only: Set<Int>? = nil) -> [Hit] {
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
            if let o = only, !o.contains(fid) { continue }
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
        // a very long list of matching pages can leave a PDF out: it still counts, just without a snippet
        if let o = only, !o.subtracting(acc.keys).isEmpty, let rows = prepare("SELECT id, path FROM files") {
            while rows.step() {
                let id = rows.int(0)
                if o.contains(id) && acc[id] == nil { acc[id] = Acc(path: rows.text(1), score: 0, pages: 0, page: 0, snippet: "") }
            }
        }
        return acc.sorted { $0.value.score < $1.value.score }.map { fid, a in
            let badge = a.pages == 0 ? "in name" : (a.pages == 1 ? "1 page" : "\(a.pages) pages")
            return Hit(id: fid, path: a.path, page: a.page, badge: badge, snippet: DB.highlight(a.snippet))
        }
    }

    /// A save of highlights/notes made in PDF Search.
    func markEdited(_ path: String, at time: Double) {
        run("INSERT OR REPLACE INTO edits(path, time) VALUES (?,?)", [path, time])
    }

    /// PDFs you've changed highlights or notes in, newest first.
    func recentFiles() -> [(id: Int, path: String, time: Double)] {
        var out: [(id: Int, path: String, time: Double)] = []
        guard let st = prepare("""
            SELECT files.id, files.path, max(coalesce(files.edited, 0), coalesce(edits.time, 0)) AS t
            FROM files LEFT JOIN edits ON edits.path = files.path
            WHERE max(coalesce(files.edited, 0), coalesce(edits.time, 0)) > 0
            ORDER BY t DESC
            LIMIT 1000
            """) else { return out }
        while st.step() { out.append((st.int(0), st.text(1), st.double(2))) }
        return out
    }

    /// PDFs by when they arrived, newest first.
    func addedFiles() -> [(id: Int, path: String, time: Double)] {
        var out: [(id: Int, path: String, time: Double)] = []
        guard let st = prepare("""
            SELECT files.id, files.path, added.time FROM files JOIN added ON added.path = files.path
            WHERE added.time > 0
            ORDER BY added.time DESC, files.id DESC
            LIMIT 500
            """) else { return out }
        while st.step() { out.append((st.int(0), st.text(1), st.double(2))) }
        return out
    }

    /// Your highlights, notes, summaries and paper-note paragraphs that match, best first.
    func searchNotes(_ query: String) -> [NoteRow] {
        var out: [NoteRow] = []
        if let st = prepare("""
            SELECT notes.rowid, files.path, notes.kind, notes.page, notes.label, notes.quote, notes.comment,
                   snippet(notes, 0, char(2), char(3), '…', 40), snippet(notes, 1, char(2), char(3), '…', 40), bm25(notes)
            FROM notes JOIN files ON files.id = notes.rowid / \(NOTE_SLOTS)
            WHERE notes MATCH ? AND notes.rowid > 0
            ORDER BY bm25(notes)
            LIMIT 2000
            """, [query]) {
            while st.step() {
                out.append(NoteRow(rowid: st.int(0), filePath: st.text(1), notePath: "", pdf: "", key: "",
                                   kind: st.text(2), page: st.int(3), label: st.text(4),
                                   quote: st.text(5), comment: st.text(6), quoteHL: st.text(7), commentHL: st.text(8),
                                   score: st.double(9)))
            }
        }
        if let st = prepare("""
            SELECT notes.rowid, notefiles.path, notefiles.pdf, notefiles.key, notes.comment,
                   snippet(notes, 1, char(2), char(3), '…', 40), bm25(notes)
            FROM notes JOIN notefiles ON notefiles.id = (-notes.rowid) / \(NOTE_SLOTS)
            WHERE notes MATCH ? AND notes.rowid < 0
            ORDER BY bm25(notes)
            LIMIT 2000
            """, [query]) {
            while st.step() {
                out.append(NoteRow(rowid: st.int(0), filePath: "", notePath: st.text(1), pdf: st.text(2), key: st.text(3),
                                   kind: "o", page: 0, label: "", quote: "", comment: st.text(4),
                                   quoteHL: "", commentHL: st.text(5), score: st.double(6)))
            }
        }
        return out.sorted { $0.score < $1.score }
    }

    /// PDFs with highlights or notes, and how many.
    func notedFiles() -> [(id: Int, path: String, count: Int)] {
        var counts: [Int: Int] = [:]
        if let st = prepare("SELECT rowid FROM notes WHERE rowid > 0") {
            while st.step() { counts[st.int(0) / NOTE_SLOTS, default: 0] += 1 }
        }
        var out: [(id: Int, path: String, count: Int)] = []
        guard !counts.isEmpty, let st = prepare("SELECT id, path FROM files") else { return out }
        while st.step() {
            if let n = counts[st.int(0)] { out.append((st.int(0), st.text(1), n)) }
        }
        return out
    }

    /// Paper notes (.md) with writing of your own, and how many paragraphs.
    func ownNoteFiles() -> [(id: Int, path: String, pdf: String, key: String, count: Int)] {
        var counts: [Int: Int] = [:]
        if let st = prepare("SELECT rowid FROM notes WHERE rowid < 0") {
            while st.step() { counts[(-st.int(0)) / NOTE_SLOTS, default: 0] += 1 }
        }
        var out: [(id: Int, path: String, pdf: String, key: String, count: Int)] = []
        guard !counts.isEmpty, let st = prepare("SELECT id, path, pdf, key FROM notefiles") else { return out }
        while st.step() {
            if let n = counts[st.int(0)] { out.append((st.int(0), st.text(1), st.text(2), st.text(3), n)) }
        }
        return out
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
