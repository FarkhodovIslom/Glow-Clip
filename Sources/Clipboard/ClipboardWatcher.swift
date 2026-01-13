import AppKit
import os.log

/// Monitors NSPasteboard for changes and forwards new content to ClipStorage
final class ClipboardWatcher {

    // MARK: - Types

    enum WatcherState {
        case idle
        case running
        case paused
    }

    // MARK: - Properties

    private let pasteboard = NSPasteboard.general
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "ClipboardWatcher")

    private var pollTimer: Timer?
    private var lastChangeCount: Int = 0
    private var state: WatcherState = .idle

    /// Interval between pasteboard checks (in seconds)
    private let pollInterval: TimeInterval = 0.5

    /// Temporarily ignore our own pastes
    private var ignoreNextChange = false

    // MARK: - Initialization

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    deinit {
        stop()
    }

    // MARK: - Public Interface

    /// Starts monitoring the pasteboard
    func start() {
        guard state != .running else {
            logger.debug("Watcher already running")
            return
        }

        lastChangeCount = pasteboard.changeCount
        state = .running

        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }

        // Ensure timer fires even during UI tracking
        if let timer = pollTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        logger.info("ClipboardWatcher started")
    }

    /// Stops monitoring the pasteboard
    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        state = .idle
        logger.info("ClipboardWatcher stopped")
    }

    /// Temporarily pauses monitoring (e.g., when pasting from our own app)
    func pause() {
        guard state == .running else { return }
        state = .paused
        logger.debug("ClipboardWatcher paused")
    }

    /// Resumes monitoring after pause
    func resume() {
        guard state == .paused else { return }
        lastChangeCount = pasteboard.changeCount
        state = .running
        logger.debug("ClipboardWatcher resumed")
    }

    /// Call this before programmatically writing to pasteboard
    func willWriteToPasteboard() {
        ignoreNextChange = true
    }

    // MARK: - Private Methods

    private func checkPasteboard() {
        guard state == .running else { return }

        let currentCount = pasteboard.changeCount
        guard currentCount != lastChangeCount else { return }

        lastChangeCount = currentCount

        if ignoreNextChange {
            ignoreNextChange = false
            logger.debug("Ignoring self-initiated pasteboard change")
            return
        }

        processPasteboardContent()
    }

    @MainActor
    private func processPasteboardContent() {
        // Priority order: files > images > text
        // This ensures we capture the most specific content type

        if processFiles() {
            return
        }

        if processImage() {
            return
        }

        processText()
    }

    @MainActor
    private func processFiles() -> Bool {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty else {
            return false
        }

        // Filter to only existing files/directories
        let existingURLs = urls.filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !existingURLs.isEmpty else {
            return false
        }

        logger.debug("Processing \(existingURLs.count) file(s)")

        if let item = ClipStorage.shared.save(fileURLs: existingURLs) {
            logger.info("Saved file clip: \(item.id)")
        }

        return true
    }

    @MainActor
    private func processImage() -> Bool {
        // Check for image types in pasteboard
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .tiff,
            .png,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ]

        let hasImageType = imageTypes.contains { pasteboard.types?.contains($0) ?? false }

        guard hasImageType else { return false }

        // Try to read as NSImage
        guard let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png),
              let image = NSImage(data: imageData) else {
            // Fallback: try reading from any image rep
            if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
               let image = images.first {
                return saveImage(image)
            }
            return false
        }

        return saveImage(image)
    }

    @MainActor
    private func saveImage(_ image: NSImage) -> Bool {
        // Validate image has actual content
        guard image.isValid, image.size.width > 0, image.size.height > 0 else {
            logger.warning("Invalid image dimensions")
            return false
        }

        logger.debug("Processing image: \(image.size.width)x\(image.size.height)")

        if let item = ClipStorage.shared.save(image: image) {
            logger.info("Saved image clip: \(item.id)")
            return true
        }

        return false
    }

    @MainActor
    private func processText() {
        guard let text = pasteboard.string(forType: .string) else {
            return
        }

        // Skip empty or whitespace-only strings
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        logger.debug("Processing text: \(trimmed.prefix(50))...")

        if let item = ClipStorage.shared.save(text: text) {
            logger.info("Saved text clip: \(item.id)")
        }
    }
}

// MARK: - Pasteboard Writing Helper

extension ClipboardWatcher {

    /// Writes a clip item back to the pasteboard
    @MainActor
    func writeToClipboard(_ item: ClipItem) {
        willWriteToPasteboard()

        guard let content = ClipStorage.shared.content(for: item) else {
            logger.error("Failed to load content for item: \(item.id)")
            return
        }

        pasteboard.clearContents()

        switch item.type {
        case .text:
            if let text = content as? String {
                pasteboard.setString(text, forType: .string)
            }

        case .image:
            if let image = content as? NSImage {
                pasteboard.writeObjects([image])
            }

        case .file:
            if let urls = content as? [URL] {
                pasteboard.writeObjects(urls as [NSURL])
            }
        }

        logger.debug("Wrote item to clipboard: \(item.id)")
    }
}
