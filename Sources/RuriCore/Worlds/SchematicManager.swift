import RuriLocalization
import Foundation
import Darwin

/// A folder that a family of schematic mods reads.
public enum SchematicLocation: String, CaseIterable, Identifiable, Sendable {
    /// `schematics/` in the run directory, shared by Litematica, Create and Schematica.
    case schematics
    /// WorldEdit's save folder below its `config/worldedit` working directory.
    case worldEdit = "worldedit"
    public var id: String { rawValue }
    public var fileExtensions: [String] { self == .worldEdit ? ["schem", "schematic"] : SchematicManager.fileExtensions }
    /// Mods that read this location, most common first.
    public var mods: [String] { self == .worldEdit ? ["WorldEdit"] : ["Litematica", "Create", "Schematica"] }
    /// Display names keyed by the mod ID each mod declares in its metadata.
    public static let modNames = ["litematica": "Litematica", "create": "Create", "schematica": "Schematica", "worldedit": "WorldEdit"]
}

public struct SchematicEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let modifiedAt: Date?
    /// The folder's contents when listed through `tree()`; `nil` for files.
    public var children: [SchematicEntry]? = nil
    public var name: String { url.lastPathComponent }
}

public struct SchematicInfo: Sendable {
    public let name: String?
    public let author: String?
    public let description: String?
    public let dimensions: [Int64]
    public let blocks: Int64?
    public let volume: Int64?
    public let regions: Int?
    public let formatVersion: Int64?
    public let gameDataVersion: Int64?
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let previewARGB: Data?
}

public actor SchematicManager {
    public static let fileExtensions = ["litematic", "schem", "schematic", "nbt"]
    public nonisolated let location: SchematicLocation
    private let paths: LauncherPaths
    private let instanceID: UUID
    private static let diskLock = NSRecursiveLock()
    private let locationLock = InstanceLocationOperationLock()
    private let operationLock = GameDataOperationLock()
    public init(paths: LauncherPaths, instanceID: UUID, location: SchematicLocation = .schematics) {
        self.paths = paths; self.instanceID = instanceID; self.location = location
    }

    /// The folder the location's mod reads, following the mod's own directory setting.
    public func directory() -> URL {
        let game = paths.game(instanceID)
        switch location {
        case .schematics:
            let config = game.appendingPathComponent("config/litematica.json")
            if let data = try? RunDirectoryCopyGuard.read(config, limit: 4 * 1024 * 1024),
               let generic = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["Generic"] as? [String: Any],
               generic["customSchematicBaseDirectoryEnabled"] as? Bool == true,
               let custom = generic["customSchematicBaseDirectory"] as? String, !custom.isEmpty {
                return Self.resolve(custom, against: game)
            }
            return game.appendingPathComponent("schematics")
        case .worldEdit:
            let working = game.appendingPathComponent("config/worldedit")
            let properties = try? RunDirectoryCopyGuard.read(working.appendingPathComponent("worldedit.properties"), limit: 1024 * 1024)
            guard let saved = properties.flatMap({ Self.property("schematic-save-dir", in: $0) }), !saved.isEmpty else { return working.appendingPathComponent("schematics") }
            return Self.resolve(saved, against: working)
        }
    }
    public func list(directory: String = "") throws -> [SchematicEntry] {
        try withLock {
            let folder = try path(directory)
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            return try contents(of: folder, relative: directory)
        }
    }
    /// Every schematic and folder in the location, nested by folder.
    public func tree() throws -> [SchematicEntry] {
        try withLock {
            let folder = try path("")
            guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
            var budget = 20_000
            func nested(_ entries: [SchematicEntry], depth: Int) throws -> [SchematicEntry] {
                budget -= entries.count
                return try entries.map { entry in
                    guard entry.isDirectory else { return entry }
                    var folder = entry
                    folder.children = depth < 32 && budget > 0 ? try nested(contents(of: entry.url, relative: entry.id), depth: depth + 1) : []
                    return folder
                }
            }
            return try nested(contents(of: folder, relative: ""), depth: 0)
        }
    }
    public func createFolder(_ name: String, directory: String = "") throws {
        try withLock {
            try validateName(name)
            let parent = try path(directory), destination = try path(directory.isEmpty ? name : directory + "/" + name)
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw RuriError.message(Messages.CoreSchematicManager.duplicateFileOrFolder) }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        }
    }
    public func importFiles(_ sources: [URL], directory: String = "") throws {
        try withLock {
            guard !sources.isEmpty, sources.count <= 200 else { throw RuriError.message(Messages.CoreSchematicManager.invalidImportFileCount) }
            let parent = try path(directory)
            var targets: [URL] = [], names = Set<String>()
            for source in sources {
                try validateName(source.lastPathComponent)
                let info = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard info.isRegularFile == true, info.isSymbolicLink != true, location.fileExtensions.contains(source.pathExtension.lowercased()) else {
                    throw RuriError.message(Messages.CoreSchematicManager.unsupportedSchematicFormat(location.fileExtensions.map { "." + $0 }.joined(separator: " / ")))
                }
                let target = parent.appendingPathComponent(source.lastPathComponent)
                guard names.insert(source.lastPathComponent.lowercased()).inserted, !FileManager.default.fileExists(atPath: target.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else {
                    throw RuriError.message(Messages.CoreSchematicManager.duplicateSchematicName(source.lastPathComponent))
                }
                targets.append(target)
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent(".ruri-import-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: staging) }
            for source in sources {
                try Task.checkCancellation()
                try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(source.lastPathComponent))
            }
            try Task.checkCancellation()
            var published: [URL] = []
            do {
                for target in targets {
                    try FileManager.default.moveItem(at: staging.appendingPathComponent(target.lastPathComponent), to: target)
                    published.append(target)
                }
            } catch { for target in published { try FileManager.default.removeItem(at: target) }; throw error }
        }
    }
    /// Renames in place. A schematic keeps its extension, so `name` is the part before it.
    public func rename(_ entry: SchematicEntry, to name: String) throws {
        try withLock {
            let source = try checked(entry)
            let filename = entry.isDirectory || entry.url.pathExtension.isEmpty ? name : name + "." + entry.url.pathExtension
            try validateName(name); try validateName(filename)
            guard filename != entry.name else { return }
            let target = source.deletingLastPathComponent().appendingPathComponent(filename)
            // A case-only change names the same file on a case-insensitive volume.
            guard filename.lowercased() == entry.name.lowercased() || !FileManager.default.fileExists(atPath: target.path),
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else { throw RuriError.message(Messages.CoreSchematicManager.duplicateFileOrFolder) }
            guard Darwin.rename(source.path, target.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
    /// Moves entries into another folder of the same location; `directory` is empty for the top level.
    public func move(_ entries: [SchematicEntry], to directory: String) throws {
        try withLock {
            let parent = try path(directory)
            var moves: [(URL, URL)] = [], names = Set<String>()
            for entry in entries {
                let source = try checked(entry)
                guard source.deletingLastPathComponent().standardizedFileURL != parent.standardizedFileURL else { continue }
                guard !entry.isDirectory || (directory != entry.id && !directory.hasPrefix(entry.id + "/")) else { throw RuriError.message(Messages.CoreSchematicManager.folderIntoItself) }
                let target = parent.appendingPathComponent(entry.name)
                guard names.insert(entry.name.lowercased()).inserted, !FileManager.default.fileExists(atPath: target.path),
                      (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else { throw RuriError.message(Messages.CoreSchematicManager.duplicateSchematicName(entry.name)) }
                moves.append((source, target))
            }
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            var done: [(URL, URL)] = []
            do {
                for (source, target) in moves { try FileManager.default.moveItem(at: source, to: target); done.append((source, target)) }
            } catch { for (source, target) in done.reversed() { try? FileManager.default.moveItem(at: target, to: source) }; throw error }
        }
    }
    public func export(_ entry: SchematicEntry, to destination: URL) throws {
        try withLock {
            let source = try checked(entry)
            guard !entry.isDirectory else { throw RuriError.message(Messages.CoreSchematicManager.singleSourceRequired) }
            guard source.resolvingSymlinksInPath() != destination.standardizedFileURL.resolvingSymlinksInPath() else { throw RuriError.message(Messages.CoreSchematicManager.exportDestinationSameAsSource) }
            let staging = destination.deletingLastPathComponent().appendingPathComponent(".ruri-export-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: source, to: staging)
            try Task.checkCancellation()
            guard Darwin.rename(staging.path, destination.path) == 0 else { throw RuriError.message(Messages.CoreSchematicManager.schematicExportSaveFailed) }
        }
    }
    @discardableResult public func remove(_ entry: SchematicEntry) throws -> URL? {
        try withLock {
            let source = try checked(entry)
            var result: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &result)
            return result as URL?
        }
    }
    public func info(_ entry: SchematicEntry) throws -> SchematicInfo {
        try withLock {
            let file = try checked(entry)
            guard !entry.isDirectory else { throw RuriError.message(Messages.CoreSchematicManager.schematicInfoMissing) }
            var reader = try NBTReader(data: RunDirectoryCopyGuard.read(file, limit: 32 * 1024 * 1024))
            let raw = try reader.read(), root = raw["Schematic"] ?? raw, metadata = root["Metadata"]
            let size: [Int64]
            if let enclosing = metadata?["EnclosingSize"] { size = ["x", "y", "z"].compactMap { enclosing[$0]?.integer } }
            else if case .list(let list) = root["size"] { size = list.compactMap(\.integer) }
            else { size = ["Width", "Height", "Length"].compactMap { root[$0]?.integer.map { Int64(UInt16(truncatingIfNeeded: $0)) } } }
            let regions: Int?
            if case .compound(let values) = root["Regions"] { regions = values.count } else { regions = nil }
            let preview: Data?
            if case .array(let data) = metadata?["PreviewImageData"], data.count <= 4 * 1024 * 1024 { preview = data } else { preview = nil }
            func date(_ value: NBTValue?) -> Date? { value?.integer.map { Date(timeIntervalSince1970: Double($0) / 1000) } }
            return SchematicInfo(name: metadata?["Name"]?.string, author: metadata?["Author"]?.string ?? root["author"]?.string,
                                 description: metadata?["Description"]?.string, dimensions: size.count == 3 ? size : [], blocks: metadata?["TotalBlocks"]?.integer,
                                 volume: metadata?["TotalVolume"]?.integer, regions: regions, formatVersion: root["Version"]?.integer,
                                 gameDataVersion: root["MinecraftDataVersion"]?.integer ?? root["DataVersion"]?.integer,
                                 createdAt: date(metadata?["TimeCreated"] ?? metadata?["Date"]), modifiedAt: date(metadata?["TimeModified"]), previewARGB: preview)
        }
    }
    private nonisolated func contents(of folder: URL, relative directory: String) throws -> [SchematicEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]).compactMap { file in
            let info = try file.resourceValues(forKeys: Set(keys))
            guard info.isSymbolicLink != true, info.isDirectory == true || info.isRegularFile == true && location.fileExtensions.contains(file.pathExtension.lowercased()) else { return nil }
            return SchematicEntry(id: directory.isEmpty ? file.lastPathComponent : directory + "/" + file.lastPathComponent, url: file, isDirectory: info.isDirectory == true, size: Int64(info.fileSize ?? 0), modifiedAt: info.contentModificationDate)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func checked(_ entry: SchematicEntry) throws -> URL {
        let file = try path(entry.id), info = try file.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        guard file.standardizedFileURL == entry.url.standardizedFileURL, entry.isDirectory ? info.isDirectory == true : info.isRegularFile == true else { throw RuriError.message(Messages.CoreSchematicManager.schematicFileChanged) }
        return file
    }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else { throw RuriError.message(Messages.CoreSchematicManager.invalidFileOrFolderName) }
    }
    private func path(_ relative: String) throws -> URL {
        let root = directory()
        var current = root
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else { throw RuriError.message(Messages.CoreSchematicManager.symlinkDirectoryUnchanged) }
        // Children are listed below the resolved root so their URLs match `safePath` results.
        if relative.isEmpty { return root.standardizedFileURL.resolvingSymlinksInPath() }
        for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
            try validateName(String(part)); current.appendPathComponent(String(part))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else { throw RuriError.message(Messages.CoreSchematicManager.symlinkUnchanged) }
        }
        return try LauncherPaths.safePath(relative, within: root)
    }
    private func withLock<T>(_ action: () throws -> T) throws -> T {
        Self.diskLock.lock(); defer { Self.diskLock.unlock() }
        try locationLock.acquire(paths: paths, instanceID: instanceID); defer { locationLock.release() }
        try paths.validateInstanceLocation(instanceID)
        try RunDirectoryCopyGuard.requireAvailable(paths: paths, instanceID: instanceID)
        try operationLock.acquire(directory: paths.gameDataState(instanceID), name: ".schematic-operation.lock"); defer { operationLock.release() }
        return try action()
    }
    /// Java resolves a relative directory setting against the mod's working directory.
    static func resolve(_ path: String, against base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }
    /// Reads one key from a Java `.properties` file, which is ISO 8859-1 with backslash escapes.
    static func property(_ key: String, in data: Data) -> String? {
        guard let text = String(data: data, encoding: .isoLatin1) else { return nil }
        func unescape(_ value: Substring) -> String {
            var result = "", characters = value.makeIterator()
            while let character = characters.next() {
                guard character == "\\" else { result.append(character); continue }
                guard let next = characters.next() else { break }
                switch next {
                case "t": result.append("\t")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "f": result.append("\u{0C}")
                case "u":
                    let hex = String((0..<4).compactMap { _ in characters.next() })
                    if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) { result.unicodeScalars.append(scalar) }
                default: result.append(next)
                }
            }
            return result
        }
        let separators: Set<Character> = ["=", ":", " ", "\t", "\u{0C}"]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
            guard let first = line.first, first != "#", first != "!" else { continue }
            var end = line.startIndex, escaped = false
            while end < line.endIndex, escaped || !separators.contains(line[end]) {
                escaped = !escaped && line[end] == "\\"; end = line.index(after: end)
            }
            guard unescape(line[..<end]) == key else { continue }
            var value = line[end...].drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" }
            if let separator = value.first, separator == "=" || separator == ":" { value = value.dropFirst().drop { $0 == " " || $0 == "\t" || $0 == "\u{0C}" } }
            return unescape(value)
        }
        return nil
    }
}
