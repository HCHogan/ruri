import RuriLocalization
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import RuriCore

/// A Finder-style browser for the folders schematic mods read: each folder is a
/// sidebar location, and its contents appear as an outline on the right.
struct SchematicManagerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let instance: GameInstance
    @State private var location = SchematicLocation.schematics
    @State private var mods: Set<String>?
    @State private var modFiles: [String: LocalContentFile] = [:]
    @State private var trees: [SchematicLocation: [SchematicEntry]] = [:]
    @State private var folders: [SchematicLocation: URL] = [:]
    @State private var failures: [SchematicLocation: String] = [:]
    @State private var loaded = false
    @State private var selection = Set<SchematicEntry.ID>()
    @State private var sortOrder = [KeyPathComparator(\SchematicEntry.displayName, comparator: .localizedStandard)]
    @State private var search = ""
    @State private var error: String?
    @State private var status: String?
    @State private var importing = false
    @State private var importDirectory = ""
    @State private var naming: Naming?
    @State private var name = ""
    @State private var removing: [SchematicEntry] = []
    @State private var inspecting: SchematicEntry?
    private enum Naming { case folder(String), rename(SchematicEntry) }
    private var manager: SchematicManager { manager(location) }
    // Mods read these folders live, so files can change while the game runs; the
    // manager's own locks still refuse instance moves and run-directory copies.
    private var canModify: Bool { loaded && !model.busy }
    private var types: [UTType] { location.fileExtensions.map { UTType(filenameExtension: $0) ?? .data } }
    private var query: String { search.trimmingCharacters(in: .whitespaces) }
    private var entries: [SchematicEntry] { trees[location] ?? [] }
    private var all: [SchematicEntry] { Self.flatten(entries) }
    private var displayed: [SchematicEntry] {
        guard !query.isEmpty else { return sorted(entries) }
        return all.filter { !$0.isDirectory && $0.name.localizedStandardContains(query) }.sorted(using: sortOrder)
    }
    private var selectedItems: [SchematicEntry] { items(selection) }
    /// Every folder whose listing affects the sidebar counts or the outline, plus
    /// the existing ancestors of a location that has not been created yet.
    private var watched: [URL] {
        let game = model.paths.game(instance.id).standardizedFileURL
        return SchematicLocation.allCases.flatMap { location -> [URL] in
            guard let root = folders[location]?.standardizedFileURL else { return [] }
            var ancestors: [URL] = [], url = root
            while !FileManager.default.fileExists(atPath: root.path), url.path.hasPrefix(game.path + "/") { url.deleteLastPathComponent(); ancestors.append(url) }
            return [root] + ancestors + Self.flatten(trees[location] ?? []).filter(\.isDirectory).map(\.url)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 200).background(.thinMaterial)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            bottomBar.padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 880, height: 600)
        .interactiveDismissDisabled(model.busy)
        .task {
            await detectMods()
            // Open WorldEdit's folder first when it is the only schematic mod installed.
            if let mods, mods.contains("WorldEdit"), !SchematicLocation.schematics.mods.contains(where: mods.contains) { location = .worldEdit }
            await reload()
        }
        .task(id: watched.map(\.path).joined(separator: "\n")) {
            guard loaded else { return }
            let observer = FileChangeObserver(directories: watched, fallbackSeconds: 10)
            defer { observer.cancel() }
            for await _ in observer.events { if Task.isCancelled { break }; await reload() }
        }
        .onChange(of: location) { _, _ in selection = []; search = ""; error = nil; status = nil }
        .fileImporter(isPresented: $importing, allowedContentTypes: types, allowsMultipleSelection: true) { result in
            do { importFiles(try result.get(), into: importDirectory, at: location) } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $inspecting) { entry in SchematicInfoView(entry: entry, manager: manager) }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(namingPrompt, text: $name)
            Button(namingConfirm) { commitNaming() }
            Button(Messages.Common.cancel.localized, role: .cancel) {}
        }
        .confirmationDialog(Messages.AppSchematicManagerView.confirmTrash.localized, isPresented: Binding(get: { !removing.isEmpty }, set: { if !$0 { removing = [] } }), titleVisibility: .visible) {
            Button(Messages.AppSchematicManagerView.trash.localized, role: .destructive) {
                let items = Self.outermost(removing), manager = manager
                mutate(Messages.AppSchematicManagerView.entryRemoval.localized) { for item in items { _ = try await manager.remove(item) } }
                removing = []
            }
        } message: { Text(removalMessage) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(Messages.AppSchematicManagerView.schematics.localized).font(.headline)
                Text(instance.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 8)
            List(SchematicLocation.allCases, selection: $location) { location in
                Label {
                    Text(title(location)).lineLimit(1)
                } icon: {
                    // The mod's own icon makes the row read as a mod, not a folder name.
                    if let file = location.mods.lazy.compactMap({ modFiles[$0] }).first { LocalContentIcon(file: file, size: 18) }
                    else { Image(systemName: "puzzlepiece.extension") }
                }.padding(.vertical, 4)
                    .badge(Self.flatten(trees[location] ?? []).count(where: { !$0.isDirectory }))
                    .help(folders[location]?.path ?? "")
                    .tag(location)
                    .dropDestination(for: URL.self) { urls, _ in guard canModify else { return false }; importFiles(urls, into: "", at: location); return true }
                    .contextMenu {
                        Button(Messages.AppSchematicManagerView.revealInFinder.localized, systemImage: "folder") { reveal(location) }
                    }
            }.listStyle(.sidebar).scrollContentBackground(.hidden)
            .accessibilityLabel(Messages.AppSchematicManagerView.location.localized)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title(location)).font(.title2.weight(.semibold)).lineLimit(1)
                    Text(displayPath(location)).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(folders[location]?.path ?? "")
                }
                Spacer(minLength: 12)
                NativeSearchField(text: $search, prompt: Messages.AppSchematicManagerView.searchSchematics.localized).frame(width: 200)
            }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 12)
            if let error = error ?? failures[location] {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 8)
            }
            Group {
                if !loaded { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if entries.isEmpty {
                    EmptyPanel(symbol: "square.3.layers.3d", title: Messages.AppSchematicManagerView.noSchematics.localized,
                               detail: Messages.AppSchematicManagerView.dropFormats(location.fileExtensions.map { "." + $0 }.joined(separator: " / ")).localized)
                        .frame(maxHeight: .infinity)
                } else { table }
            }
            .contentShape(Rectangle())
            .dropDestination(for: URL.self) { urls, _ in guard canModify else { return false }; importFiles(urls, into: "", at: location); return true }
        }
    }

    private var table: some View {
        let rows = displayed
        return Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(Messages.AppSchematicManagerView.name.localized, value: \.displayName, comparator: .localizedStandard) { entry in
                let parent = query.isEmpty ? "" : Self.parent(of: entry)
                HStack(spacing: 7) {
                    Image(systemName: entry.isDirectory ? "folder.fill" : "square.3.layers.3d")
                        .foregroundStyle(entry.isDirectory ? Theme.accent : Color.secondary).frame(width: 18)
                    Text(entry.displayName).lineLimit(1).truncationMode(.middle)
                    // Search results are flat, so show where each match lives.
                    if !parent.isEmpty { Text(parent).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head) }
                }.help(entry.id)
            }.width(min: 200, ideal: 300)
            TableColumn(Messages.AppSchematicManagerView.kind.localized, value: \.kind) { entry in
                Text(entry.isDirectory ? Messages.AppSchematicManagerView.folderKind.localized : entry.kind).foregroundStyle(.secondary)
            }.width(min: 70, ideal: 90)
            TableColumn(Messages.AppSchematicManagerView.sizeColumn.localized, value: \.size) { entry in
                Text(entry.isDirectory ? "--" : LocalizedFormat.bytes(entry.size)).foregroundStyle(.secondary).monospacedDigit()
            }.width(min: 60, ideal: 70)
            TableColumn(Messages.AppSchematicManagerView.modifiedColumn.localized, value: \.modified) { entry in
                Text(entry.modifiedAt.map { LocalizedFormat.date($0, date: .abbreviated, time: .shortened) } ?? "--").foregroundStyle(.secondary)
            }.width(min: 120, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: SchematicEntry.ID.self) { ids in menu(items(ids)) } primaryAction: { ids in
            let items = items(ids)
            if items.count == 1, let item = items.first, !item.isDirectory { inspecting = item }
        }
        .onDeleteCommand { if canModify, !selectedItems.isEmpty { removing = selectedItems } }
        .onKeyPress(.space) {
            let items = selectedItems
            guard items.count == 1, let item = items.first, !item.isDirectory else { return .ignored }
            inspecting = item; return .handled
        }
        .overlay { if rows.isEmpty { ContentUnavailableView(Messages.AppSchematicManagerView.noResults(query).localized, systemImage: "magnifyingglass") } }
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button(Messages.AppSchematicManagerView.newFolder.localized) { beginNaming(.folder("")) }.disabled(!canModify)
            Button(Messages.AppSchematicManagerView.importSchematics.localized) { beginImport("") }.disabled(!canModify)
            Button(Messages.AppSchematicManagerView.revealInFinder.localized) { reveal(location) }.disabled(folders[location] == nil)
            if let status { Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(status) }
            Spacer(minLength: 8)
            if model.busy {
                ProgressView().controlSize(.small)
                Button(Messages.AppSchematicManagerView.cancelTask.localized) { model.operation?.cancel() }
            }
            Button(Messages.Common.done.localized) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.borderedProminent).disabled(model.busy)
        }
    }

    /// Context menus list only what applies right now: unavailable items are
    /// hidden rather than dimmed, so a folder with nowhere to go has no Move To.
    @ViewBuilder private func menu(_ items: [SchematicEntry]) -> some View {
        if items.isEmpty {
            if canModify {
                Button(Messages.AppSchematicManagerView.newFolder.localized, systemImage: "folder.badge.plus") { beginNaming(.folder("")) }
                Button(Messages.AppSchematicManagerView.importSchematics.localized, systemImage: "square.and.arrow.down") { beginImport("") }
                Divider()
            }
            Button(Messages.AppSchematicManagerView.revealInFinder.localized, systemImage: "folder") { reveal(location) }
        } else {
            if items.count == 1, let item = items.first {
                if item.isDirectory {
                    if canModify {
                        Button(Messages.AppSchematicManagerView.newFolder.localized, systemImage: "folder.badge.plus") { beginNaming(.folder(item.id)) }
                        Button(Messages.AppSchematicManagerView.importHere.localized, systemImage: "square.and.arrow.down") { beginImport(item.id) }
                    }
                } else {
                    Button(Messages.AppSchematicManagerView.viewInfo.localized, systemImage: "info.circle") { inspecting = item }
                    if canModify { Button(Messages.AppSchematicManagerView.exportSchematics.localized, systemImage: "square.and.arrow.up") { export(item) } }
                }
                if canModify {
                    Divider()
                    Button(Messages.AppSchematicManagerView.renameMenu.localized, systemImage: "pencil") { beginNaming(.rename(item)) }
                }
            }
            if canModify {
                let targets = moveTargets(items)
                if !targets.isEmpty {
                    Menu(Messages.AppSchematicManagerView.moveTo.localized, systemImage: "arrowshape.turn.up.right") {
                        ForEach(targets, id: \.self) { target in
                            Button(target.isEmpty ? folders[location]?.lastPathComponent ?? location.rawValue : target) { move(items, to: target) }
                        }
                    }
                }
                ForEach(copyTargets(items)) { target in
                    Button(Messages.AppSchematicManagerView.copyTo(title(target)).localized, systemImage: "doc.on.doc") { copy(items, to: target) }
                }
            }
            Divider()
            Button(Messages.AppSchematicManagerView.revealInFinder.localized, systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url)) }
            if canModify {
                Divider()
                Button(Messages.AppSchematicManagerView.trashSchematics.localized, systemImage: "trash", role: .destructive) { removing = items }
            }
        }
    }

    private func manager(_ location: SchematicLocation) -> SchematicManager { SchematicManager(paths: model.paths, instanceID: instance.id, location: location) }
    /// The mods that read a location, limited to installed ones when any are found.
    private func title(_ location: SchematicLocation) -> String {
        let found = location.mods.filter { mods?.contains($0) == true }
        return (found.isEmpty ? Array(location.mods.prefix(1)) : found).joined(separator: " · ")
    }
    /// The location's folder relative to the run directory, or its full path when the mod points elsewhere.
    private func displayPath(_ location: SchematicLocation) -> String {
        guard let folder = folders[location] else { return "" }
        let game = model.paths.game(instance.id).standardizedFileURL.path + "/", path = folder.standardizedFileURL.path
        return path.hasPrefix(game) ? String(path.dropFirst(game.count)) : (path as NSString).abbreviatingWithTildeInPath
    }
    private var namingTitle: String {
        if case .rename = naming { return Messages.AppSchematicManagerView.renameTitle.localized }
        return Messages.AppSchematicManagerView.newFolder.localized
    }
    private var namingPrompt: String {
        if case .rename = naming { return Messages.AppSchematicManagerView.name.localized }
        return Messages.AppSchematicManagerView.folderName.localized
    }
    private var namingConfirm: String {
        if case .rename = naming { return Messages.AppSchematicManagerView.renameTitle.localized }
        return Messages.AppSchematicManagerView.createFolder.localized
    }
    private var removalMessage: String {
        guard removing.count == 1, let item = removing.first else { return Messages.AppSchematicManagerView.itemCount(Int64(removing.count)).localized }
        return item.isDirectory ? Messages.AppSchematicManagerView.directoryRemovalDescription(item.displayName).localized : item.displayName
    }
    /// Folders the items can move into: the top level and every folder outside the moved ones.
    private func moveTargets(_ items: [SchematicEntry]) -> [String] {
        let parents = Set(items.map(Self.parent))
        return ([""] + all.filter(\.isDirectory).map(\.id)).filter { target in
            !(parents.count == 1 && parents.contains(target)) && !items.contains { $0.isDirectory && (target == $0.id || target.hasPrefix($0.id + "/")) }
        }
    }
    private func copyTargets(_ items: [SchematicEntry]) -> [SchematicLocation] {
        SchematicLocation.allCases.filter { target in
            target != location && items.allSatisfy { !$0.isDirectory && target.fileExtensions.contains($0.url.pathExtension.lowercased()) }
        }
    }
    private func items(_ ids: Set<SchematicEntry.ID>) -> [SchematicEntry] { all.filter { ids.contains($0.id) } }
    private func sorted(_ entries: [SchematicEntry]) -> [SchematicEntry] {
        entries.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : sortOrder.compare($0, $1) == .orderedAscending }
            .map { entry in var entry = entry; entry.children = entry.children.map(sorted); return entry }
    }
    private static func flatten(_ entries: [SchematicEntry]) -> [SchematicEntry] { entries.flatMap { [$0] + flatten($0.children ?? []) } }
    private static func parent(of entry: SchematicEntry) -> String { entry.id.split(separator: "/").dropLast().joined(separator: "/") }
    /// Drops items whose folder is also selected, so each file is handled once.
    private static func outermost(_ items: [SchematicEntry]) -> [SchematicEntry] {
        items.filter { item in !items.contains { $0.isDirectory && item.id.hasPrefix($0.id + "/") } }
    }

    private func beginNaming(_ target: Naming) {
        if case .rename(let entry) = target { name = entry.displayName } else { name = "" }
        naming = target
    }
    private func commitNaming() {
        guard let naming else { return }
        let manager = manager, name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch naming {
        case .folder(let parent):
            mutate(Messages.AppSchematicManagerView.newSchematicFolder.localized) {
                try await manager.createFolder(name, directory: parent); selection = [parent.isEmpty ? name : parent + "/" + name]
            }
        case .rename(let entry):
            mutate(Messages.AppSchematicManagerView.renameEntry.localized) { try await manager.rename(entry, to: name) }
        }
        self.naming = nil
    }
    private func beginImport(_ directory: String) { importDirectory = directory; importing = true }
    private func importFiles(_ urls: [URL], into directory: String, at location: SchematicLocation) {
        let manager = manager(location)
        mutate(Messages.AppSchematicManagerView.importSchematicFiles.localized) {
            let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }; defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            try await manager.importFiles(urls, directory: directory)
        }
    }
    private func move(_ items: [SchematicEntry], to directory: String) {
        let items = Self.outermost(items), manager = manager
        mutate(Messages.AppSchematicManagerView.moveEntries.localized) {
            try await manager.move(items, to: directory)
            selection = Set(items.map { directory.isEmpty ? $0.name : directory + "/" + $0.name })
        }
    }
    private func copy(_ items: [SchematicEntry], to target: SchematicLocation) {
        let destination = manager(target), label = title(target)
        mutate(Messages.AppSchematicManagerView.copyEntries.localized) {
            try await destination.importFiles(items.map(\.url)); status = Messages.AppSchematicManagerView.copiedTo(label).localized
        }
    }
    private func export(_ entry: SchematicEntry) {
        let manager = manager, panel = NSSavePanel(); panel.nameFieldStringValue = entry.name
        panel.allowedContentTypes = [UTType(filenameExtension: entry.url.pathExtension) ?? .data]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        mutate(Messages.AppSchematicManagerView.exportDestination.localized) { try await manager.export(entry, to: destination); model.report(Messages.AppSchematicManagerView.exportedSchematic, fileURL: destination) }
    }
    private func reveal(_ location: SchematicLocation) {
        guard let folder = folders[location] else { return }
        let game = model.paths.game(instance.id).standardizedFileURL.path + "/", path = folder.standardizedFileURL.path
        if path.hasPrefix(game) { model.reveal(instance, folder: String(path.dropFirst(game.count))); return }
        // A folder set in the mod's config may not exist yet; open the nearest one that does.
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        NSWorkspace.shared.open(url)
    }
    /// Finds enabled schematic mods by the IDs in their metadata, reading only jars
    /// whose names suggest one so the sidebar can show each mod's own icon.
    private func detectMods() async {
        let paths = model.paths
        guard let files = try? await ContentManager(paths: paths, instanceID: instance.id).scan(.mod, cachedOnly: true) else { mods = []; return }
        let pending = files.filter { file in
            file.enabled && !file.metadataLoaded && SchematicLocation.modNames.keys.contains { file.filename.lowercased().contains($0) }
        }
        let batches = MetadataBatches()
        await ContentMetadataLoader.enrich(pending, cacheDirectory: paths.cache) { batch in await batches.add(batch) }
        let found = Self.matched(files).merging(Self.matched(await batches.files)) { first, _ in first }
        modFiles = found; mods = Set(found.keys)
    }
    private nonisolated static func matched(_ files: [LocalContentFile]) -> [String: LocalContentFile] {
        Dictionary(files.compactMap { file in
            file.enabled ? file.modID.flatMap { SchematicLocation.modNames[$0.lowercased()] }.map { ($0, file) } : nil
        }, uniquingKeysWith: { first, _ in first })
    }
    /// Lists every location so the sidebar counts stay current with the visible outline.
    private func reload() async {
        var trees: [SchematicLocation: [SchematicEntry]] = [:], folders: [SchematicLocation: URL] = [:], failures: [SchematicLocation: String] = [:]
        for location in SchematicLocation.allCases {
            let manager = manager(location)
            folders[location] = await manager.directory()
            do { trees[location] = try await manager.tree() } catch { failures[location] = error.localizedDescription }
        }
        guard !Task.isCancelled else { return }
        // Unchanged listings keep the outline's rows and selection untouched.
        if self.trees != trees { self.trees = trees }
        if self.folders != folders { self.folders = folders }
        if self.failures != failures { self.failures = failures }
        loaded = true
        selection.formIntersection(Self.flatten(trees[location] ?? []).map(\.id))
    }
    private func mutate(_ title: String, action: @MainActor @Sendable @escaping () async throws -> Void) {
        guard canModify else { return }; error = nil; status = nil
        model.perform(title, presentErrors: false) { _ in
            do { try await action(); await reload() }
            catch { self.error = error.localizedDescription; await reload(); throw error }
        }
    }
}

private actor MetadataBatches {
    private(set) var files: [LocalContentFile] = []
    func add(_ batch: [LocalContentFile]) { files += batch }
}

private extension SchematicEntry {
    /// Finder hides extensions by default; the Kind column shows the format instead.
    var displayName: String { isDirectory ? name : url.deletingPathExtension().lastPathComponent }
    var kind: String { isDirectory ? "" : url.pathExtension.uppercased() }
    var modified: Date { modifiedAt ?? .distantPast }
}

private struct SchematicInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let entry: SchematicEntry
    let manager: SchematicManager
    @State private var info: SchematicInfo?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionHeading(title: info?.name?.isEmpty == false ? info!.name! : entry.name, subtitle: entry.name)
            if let info {
                if let data = info.previewARGB, let preview = image(data) { Image(nsImage: preview).resizable().interpolation(.none).scaledToFit().frame(maxWidth: .infinity, maxHeight: 160) }
                if let description = info.description, !description.isEmpty { Text(description).font(.callout).textSelection(.enabled) }
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    if let author = info.author, !author.isEmpty { row(Messages.AppSchematicManagerView.author.localized, author) }
                    if !info.dimensions.isEmpty { row(Messages.AppSchematicManagerView.size.localized, info.dimensions.map(String.init).joined(separator: " × ")) }
                    if let blocks = info.blocks { row(Messages.AppSchematicManagerView.blocks.localized, LocalizedFormat.number(blocks)) }
                    if let volume = info.volume { row(Messages.AppSchematicManagerView.volume.localized, LocalizedFormat.number(volume)) }
                    if let regions = info.regions { row(Messages.AppSchematicManagerView.regions.localized, LocalizedFormat.number(regions)) }
                    if let version = info.formatVersion { row(Messages.AppSchematicManagerView.formatVersion.localized, String(version)) }
                    if let version = info.gameDataVersion { row(Messages.AppSchematicManagerView.gameDataVersion.localized, String(version)) }
                    if let date = info.createdAt { row(Messages.AppSchematicManagerView.createdAt.localized, LocalizedFormat.date(date, date: .abbreviated, time: .shortened)) }
                    if let date = info.modifiedAt { row(Messages.AppSchematicManagerView.modifiedAt.localized, LocalizedFormat.date(date, date: .abbreviated, time: .shortened)) }
                    row(Messages.AppSchematicManagerView.fileSize.localized, LocalizedFormat.bytes(entry.size))
                }
            } else if let error { Text(Messages.AppSchematicManagerView.previewError(error).localized).font(.callout).foregroundStyle(.orange) }
            else { ProgressView(Messages.AppSchematicManagerView.readingSchematic.localized) }
            HStack { Spacer(); Button(Messages.Common.done.localized) { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580)
        .task { do { info = try await manager.info(entry) } catch { self.error = error.localizedDescription } }
    }
    private func row(_ title: String, _ value: String) -> some View { GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) } }
    private func image(_ data: Data) -> NSImage? {
        let pixels = data.count / 4, edge = Int(Double(pixels).squareRoot())
        guard edge > 0, edge * edge == pixels, data.count == pixels * 4,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: edge, height: edge, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: edge * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: edge, height: edge))
    }
}
