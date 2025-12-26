import Foundation
import AppKit
import os.log

/// Thread-safe singleton for managing clipboard history persistence
final class ClipStorage {

    // MARK: - Singleton

    static let shared = ClipStorage()

    // MARK: - Constants

    private enum Constants {
        static let maxItems = 30
        static let clipsFileName = "clips.json"
        static let containerIdentifier = "com.hansoftware.sonarclip"
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.glowclip.storage", qos: .userInitiated)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "ClipStorage")

    private var items: [ClipItem] = []
    private var isDirty = false

    /// Base directory for all clip data
    private lazy var clipsDirectory: URL = {
        let appSupport = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let containerPath = appSupport
            .appendingPathComponent("Containers")
            .appendingPathComponent(Constants.containerIdentifier)
            .appendingPathComponent("Data")
            .appendingPathComponent("Clips")

        do {
            try fileManager.createDirectory(at: containerPath, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create clips directory: \(error.localizedDescription)")
        }

        return containerPath
    }()

    /// Path to the JSON database file
    private var databasePath: URL {
        clipsDirectory.appendingPathComponent(Constants.clipsFileName)
    }

    // MARK: - Initialization

    private init() {
        loadFromDisk()
    }

    // MARK: - Public Interface

    /// Returns all items, sorted by date (newest first), with pinned items at the top
    func allItems() -> [ClipItem] {
        queue.sync {
            items.sorted { lhs, rhs in
                if lhs.pinned != rhs.pinned {
                    return lhs.pinned
                }
                return lhs.date > rhs.date
            }
        }
    }

    /// Returns item count
    var count: Int {
        queue.sync { items.count }
    }

    /// Saves a text clip
    @discardableResult
    func save(text: String) -> ClipItem? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        // Check for duplicate of most recent non-pinned text item
        if let duplicate = findDuplicateText(text) {
            return duplicate
        }

        let id = UUID()
        let filename = "\(id.uuidString).txt"
        let filePath = clipsDirectory.appendingPathComponent(filename)

        do {
            try text.write(to: filePath, atomically: true, encoding: .utf8)
        } catch {
            logger.error("Failed to save text clip: \(error.localizedDescription)")
            return nil
        }

        let preview = String(text.prefix(500))
        let item = ClipItem(
            id: id,
            type: .text,
            path: filename,
            preview: preview
        )

        addItem(item)
        return item
    }

    /// Saves an image clip
    @discardableResult
    func save(image: NSImage) -> ClipItem? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            logger.error("Failed to convert image to PNG")
            return nil
        }

        let id = UUID()
        let filename = "\(id.uuidString).png"
        let filePath = clipsDirectory.appendingPathComponent(filename)

        do {
            try pngData.write(to: filePath, options: .atomic)
        } catch {
            logger.error("Failed to save image clip: \(error.localizedDescription)")
            return nil
        }

        let item = ClipItem(
            id: id,
            type: .image,
            path: filename
        )

        addItem(item)
        return item
    }

    /// Saves a file reference clip
    @discardableResult
    func save(fileURLs: [URL]) -> ClipItem? {
        guard !fileURLs.isEmpty else { return nil }

        let id = UUID()
        let filename = "\(id.uuidString).files.json"
        let filePath = clipsDirectory.appendingPathComponent(filename)

        // Store file paths as JSON array
        let paths = fileURLs.map { $0.path }

        do {
            let data = try JSONEncoder().encode(paths)
            try data.write(to: filePath, options: .atomic)
        } catch {
            logger.error("Failed to save file clip: \(error.localizedDescription)")
            return nil
        }

        let displayName: String
        if fileURLs.count == 1 {
            displayName = fileURLs[0].lastPathComponent
        } else {
            displayName = "\(fileURLs.count) files"
        }

        let item = ClipItem(
            id: id,
            type: .file,
            path: filename,
            originalFilename: displayName
        )

        addItem(item)
        return item
    }

    /// Retrieves the content for a clip item
    func content(for item: ClipItem) -> Any? {
        let filePath = clipsDirectory.appendingPathComponent(item.path)

        guard fileManager.fileExists(atPath: filePath.path) else {
            logger.warning("Content file not found: \(item.path)")
            return nil
        }

        switch item.type {
        case .text:
            return try? String(contentsOf: filePath, encoding: .utf8)

        case .image:
            return NSImage(contentsOf: filePath)

        case .file:
            guard let data = try? Data(contentsOf: filePath),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                return nil
            }
            return paths.map { URL(fileURLWithPath: $0) }
        }
    }

    /// Toggles the pinned state of an item
    func togglePin(for itemId: UUID) {
        queue.async { [weak self] in
            guard let self = self,
                  let index = self.items.firstIndex(where: { $0.id == itemId }) else {
                return
            }

            self.items[index].pinned.toggle()
            self.isDirty = true
            self.saveToDisk()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
            }
        }
    }

    /// Deletes a specific item
    func delete(itemId: UUID) {
        queue.async { [weak self] in
            guard let self = self,
                  let index = self.items.firstIndex(where: { $0.id == itemId }) else {
                return
            }

            let item = self.items.remove(at: index)
            self.deleteFile(for: item)
            self.isDirty = true
            self.saveToDisk()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
            }
        }
    }

    /// Clears all non-pinned items
    func clearHistory() {
        queue.async { [weak self] in
            guard let self = self else { return }

            let toDelete = self.items.filter { !$0.pinned }
            toDelete.forEach { self.deleteFile(for: $0) }

            self.items.removeAll { !$0.pinned }
            self.isDirty = true
            self.saveToDisk()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
            }
        }
    }

    // MARK: - Private Methods

    private func addItem(_ item: ClipItem) {
        queue.async { [weak self] in
            guard let self = self else { return }

            self.items.insert(item, at: 0)
            self.enforceLimit()
            self.isDirty = true
            self.saveToDisk()

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
            }
        }
    }

    private func findDuplicateText(_ text: String) -> ClipItem? {
        queue.sync {
            // Check if the most recent text item has the same content
            guard let recentText = items.first(where: { $0.type == .text && !$0.pinned }) else {
                return nil
            }

            let filePath = clipsDirectory.appendingPathComponent(recentText.path)
            guard let existingText = try? String(contentsOf: filePath, encoding: .utf8),
                  existingText == text else {
                return nil
            }

            return recentText
        }
    }

    private func enforceLimit() {
        // Remove oldest non-pinned items if over limit
        let unpinnedItems = items.filter { !$0.pinned }
        let pinnedCount = items.count - unpinnedItems.count
        let maxUnpinned = Constants.maxItems - pinnedCount

        if unpinnedItems.count > maxUnpinned {
            let sortedUnpinned = unpinnedItems.sorted { $0.date > $1.date }
            let toRemove = Array(sortedUnpinned.dropFirst(max(0, maxUnpinned)))

            for item in toRemove {
                deleteFile(for: item)
                items.removeAll { $0.id == item.id }
            }
        }
    }

    private func deleteFile(for item: ClipItem) {
        let filePath = clipsDirectory.appendingPathComponent(item.path)
        try? fileManager.removeItem(at: filePath)
    }

    private func loadFromDisk() {
        queue.async { [weak self] in
            guard let self = self else { return }

            guard self.fileManager.fileExists(atPath: self.databasePath.path) else {
                self.logger.info("No existing database found, starting fresh")
                return
            }

            do {
                let data = try Data(contentsOf: self.databasePath)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                self.items = try decoder.decode([ClipItem].self, from: data)
                self.logger.info("Loaded \(self.items.count) items from disk")
            } catch {
                self.logger.error("Failed to load database: \(error.localizedDescription)")
            }
        }
    }

    private func saveToDisk() {
        guard isDirty else { return }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let data = try encoder.encode(items)
            try data.write(to: databasePath, options: .atomic)
            isDirty = false
            logger.debug("Saved \(self.items.count) items to disk")
        } catch {
            logger.error("Failed to save database: \(error.localizedDescription)")
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let clipStorageDidUpdate = Notification.Name("clipStorageDidUpdate")
}
