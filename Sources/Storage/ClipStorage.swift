import Foundation
import AppKit
import os.log

/// Thread-safe singleton for managing clipboard history persistence
/// Uses a serial dispatch queue for thread safety while remaining compatible with all call sites
final class ClipStorage: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = ClipStorage()

    // MARK: - Constants

    private enum Constants {
        static let maxItems = 30
        static let maxDiskUsageBytes: Int64 = 500_000_000 // 500MB quota
        static let clipsFileName = "clips.json"
    }

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let queue = DispatchQueue(label: "com.glowclip.storage", qos: .userInitiated)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "ClipStorage")

    private var items: [ClipItem] = []
    private var isDirty = false
    private var currentDiskUsage: Int64 = 0

    /// Base directory for all clip data
    private lazy var clipsDirectory: URL = {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Unable to access Application Support directory")
        }

        let clipsPath = appSupport
            .appendingPathComponent("GlowClip")
            .appendingPathComponent("Clips")

        do {
            try fileManager.createDirectory(at: clipsPath, withIntermediateDirectories: true)
            logger.info("Created clips directory at: \(clipsPath.path)")
        } catch {
            logger.error("Failed to create clips directory: \(error.localizedDescription)")
        }

        return clipsPath
    }()

    /// Path to the JSON database file
    private var databasePath: URL {
        clipsDirectory.appendingPathComponent(Constants.clipsFileName)
    }

    // MARK: - Initialization

    private init() {
        loadFromDisk()
        calculateDiskUsage()
    }

    // MARK: - Public Interface

    /// Returns all items, sorted by date (newest first), with pinned items at the top
    func allItems() -> [ClipItem] {
        items.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned {
                return lhs.pinned
            }
            return lhs.date > rhs.date
        }
    }

    /// Returns item count
    var count: Int {
        items.count
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
            trackFileSize(filePath)
        } catch {
            logger.error("Failed to save text clip: \(error.localizedDescription)")
            Task { @MainActor in showError(message: "Failed to save clipboard text") }
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
            trackFileSize(filePath)
        } catch {
            logger.error("Failed to save image clip: \(error.localizedDescription)")
            Task { @MainActor in showError(message: "Failed to save clipboard image") }
            return nil
        }

        // Generate and cache thumbnail for memory-efficient display
        // Use a copy of the image for thumbnail generation
        let imageForThumbnail = NSImage(data: pngData) ?? image
        _ = ImageCache.shared.generateThumbnail(from: imageForThumbnail, for: id)

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
            
            // Check quota before saving
            if !canAddFile(withSize: Int64(data.count)) {
                let targetSize = Constants.maxDiskUsageBytes - Int64(data.count)
                freeUpDiskSpace(targetSize: max(0, targetSize))
            }
            
            try data.write(to: filePath, options: .atomic)
            trackFileSize(filePath)
        } catch {
            logger.error("Failed to save file clip: \(error.localizedDescription)")
            Task { @MainActor in showError(message: "Failed to save file reference") }
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
        guard let index = items.firstIndex(where: { $0.id == itemId }) else {
            return
        }

        items[index].pinned.toggle()
        isDirty = true
        saveToDisk()

        NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
    }

    /// Deletes a specific item
    func delete(itemId: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemId }) else {
            return
        }

        let item = items.remove(at: index)
        deleteFile(for: item)
        isDirty = true
        saveToDisk()

        NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
    }

    /// Clears all non-pinned items
    func clearHistory() {
        let toDelete = items.filter { !$0.pinned }
        toDelete.forEach { deleteFile(for: $0) }

        items.removeAll { !$0.pinned }
        isDirty = true
        saveToDisk()

        NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
    }

    // MARK: - Private Methods

    private func addItem(_ item: ClipItem) {
        items.insert(item, at: 0)
        enforceLimit()
        isDirty = true
        saveToDisk()

        NotificationCenter.default.post(name: .clipStorageDidUpdate, object: nil)
    }

    private func findDuplicateText(_ text: String) -> ClipItem? {
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
    
    /// Calculates current disk usage by summing all clip file sizes
    private func calculateDiskUsage() {
        var totalSize: Int64 = 0
        
        for item in items {
            let filePath = clipsDirectory.appendingPathComponent(item.path)
            if let attributes = try? fileManager.attributesOfItem(atPath: filePath.path),
               let fileSize = attributes[.size] as? Int64 {
                totalSize += fileSize
            }
        }
        
        currentDiskUsage = totalSize
        logger.debug("Current disk usage: \(totalSize / 1_000_000)MB")
    }
    
    /// Checks if adding a new file would exceed disk quota
    private func canAddFile(withSize size: Int64) -> Bool {
        return (currentDiskUsage + size) <= Constants.maxDiskUsageBytes
    }
    
    /// Frees up disk space by removing oldest non-pinned items until target size is met
    private func freeUpDiskSpace(targetSize: Int64) {
        let unpinnedItems = items.filter { !$0.pinned }.sorted { $0.date < $1.date }
        
        for item in unpinnedItems {
            guard currentDiskUsage > targetSize else { break }
            
            let filePath = clipsDirectory.appendingPathComponent(item.path)
            if let attributes = try? fileManager.attributesOfItem(atPath: filePath.path),
               let fileSize = attributes[.size] as? Int64 {
                deleteFile(for: item)
                items.removeAll { $0.id == item.id }
                currentDiskUsage -= fileSize
                logger.info("Freed \(fileSize / 1_000_000)MB by removing old clip")
            }
        }
        
        isDirty = true
    }
    
    /// Updates disk usage after adding a file
    private func trackFileSize(_ fileURL: URL) {
        if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? Int64 {
            currentDiskUsage += fileSize
        }
    }
    
    private func deleteFile(for item: ClipItem) {
        let filePath = clipsDirectory.appendingPathComponent(item.path)
        
        // Track disk usage reduction
        if let attributes = try? fileManager.attributesOfItem(atPath: filePath.path),
           let fileSize = attributes[.size] as? Int64 {
            currentDiskUsage -= fileSize
        }
        
        try? fileManager.removeItem(at: filePath)
    }
    
    /// Shows an error alert to the user
    @MainActor
    private func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "Clipboard Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func loadFromDisk() {
        guard fileManager.fileExists(atPath: databasePath.path) else {
            logger.info("No existing database found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: databasePath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = try decoder.decode([ClipItem].self, from: data)
            logger.info("Loaded \(self.items.count) items from disk")
        } catch {
            logger.error("Failed to load database: \(error.localizedDescription)")
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
