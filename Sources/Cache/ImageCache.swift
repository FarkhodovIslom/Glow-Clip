import Foundation
import AppKit
import os.log

/// Memory-efficient image cache using NSCache for automatic memory management
final class ImageCache: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = ImageCache()

    // MARK: - Types

    enum CacheType {
        case thumbnail(maxSize: CGSize)
        case preview(maxSize: CGSize)

        var maxBytes: Int {
            switch self {
            case .thumbnail:
                return 500_000 // ~500KB per image
            case .preview:
                return 2_000_000 // ~2MB per image
            }
        }
    }

    // MARK: - Properties

    private let thumbnailCache = NSCache<NSString, CGImage>()
    private let previewCache = NSCache<NSString, CGImage>()
    private lazy var diskCacheURL: URL = {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cacheDir.appendingPathComponent("GlowClipImageCache", isDirectory: true)
    }()
    private let fileManager = FileManager.default
    private let ioQueue = DispatchQueue(label: "com.glowclip.imagecache.io", qos: .utility)
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "ImageCache")

    private let maxDiskCacheSize: Int = 50_000_000 // 50MB
    private var diskCacheSize: Int = 0

    // MARK: - Initialization

    private init() {
        // Setup caches
        setupCache(thumbnailCache, limit: 50, costLimit: 25_000_000) // 25MB
        setupCache(previewCache, limit: 20, costLimit: 40_000_000) // 40MB

        // Setup disk cache
        setupDiskCache()

        // Listen for memory pressure via AppKit
        setupMemoryPressureHandling()
    }

    private func setupCache(_ cache: NSCache<NSString, CGImage>, limit: Int, costLimit: Int) {
        cache.countLimit = limit
        cache.totalCostLimit = costLimit
        cache.evictsObjectsWithDiscardedContent = true
    }

    private func setupDiskCache() {
        do {
            try fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create disk cache directory: \(error.localizedDescription)")
        }
    }

    private func setupMemoryPressureHandling() {
        // Listen for app becoming inactive as a proxy for good cleanup time
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )

        // Listen for app termination
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryPressure),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc private func handleMemoryPressure() {
        logger.warning("Memory pressure detected - clearing image caches")
        clearAllCaches()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Interface

    /// Retrieves a cached image, generating it from disk if not in memory cache
    func image(for itemId: UUID, type: CacheType) -> CGImage? {
        let key = cacheKey(for: itemId)

        // Try memory cache first
        switch type {
        case .thumbnail(let maxSize):
            if let cached = thumbnailCache.object(forKey: key as NSString) {
                return cached
            }
            // Try to load from disk
            if let diskImage = loadFromDisk(key: key, type: type) {
                thumbnailCache.setObject(diskImage, forKey: key as NSString, cost: diskImageBytes(diskImage))
                return diskImage
            }

        case .preview(let maxSize):
            if let cached = previewCache.object(forKey: key as NSString) {
                return cached
            }
            if let diskImage = loadFromDisk(key: key, type: type) {
                previewCache.setObject(diskImage, forKey: key as NSString, cost: diskImageBytes(diskImage))
                return diskImage
            }
        }

        return nil
    }

    /// Stores an image in both memory and disk cache
    func store(_ image: CGImage, for itemId: UUID, type: CacheType) {
        let key = cacheKey(for: itemId)
        let cost = diskImageBytes(image)

        switch type {
        case .thumbnail:
            thumbnailCache.setObject(image, forKey: key as NSString, cost: cost)

        case .preview:
            previewCache.setObject(image, forKey: key as NSString, cost: cost)
        }

        // Save to disk asynchronously
        ioQueue.async { [weak self] in
            self?.saveToDisk(image, key: key, type: type)
        }
    }

    /// Generates and caches a thumbnail from an image
    func generateThumbnail(from image: NSImage, for itemId: UUID, maxSize: CGSize = CGSize(width: 200, height: 200)) -> CGImage? {
        let resized = resizeImage(image, maxSize: maxSize)
        if let resized = resized {
            store(resized, for: itemId, type: .thumbnail(maxSize: maxSize))
        }
        return resized
    }

    /// Generates and caches a preview from an image
    func generatePreview(from image: NSImage, for itemId: UUID, maxSize: CGSize = CGSize(width: 600, height: 400)) -> CGImage? {
        let resized = resizeImage(image, maxSize: maxSize)
        if let resized = resized {
            store(resized, for: itemId, type: .preview(maxSize: maxSize))
        }
        return resized
    }

    /// Removes a specific item from all caches
    func remove(itemId: UUID) {
        let key = cacheKey(for: itemId)

        thumbnailCache.removeObject(forKey: key as NSString)
        previewCache.removeObject(forKey: key as NSString)

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            let thumbnailPath = self.diskCacheURL.appendingPathComponent("\(key)_thumb.jpg")
            let previewPath = self.diskCacheURL.appendingPathComponent("\(key)_preview.jpg")

            try? self.fileManager.removeItem(at: thumbnailPath)
            try? self.fileManager.removeItem(at: previewPath)
        }
    }

    /// Clears all memory and disk caches
    func clearAllCaches() {
        thumbnailCache.removeAllObjects()
        previewCache.removeAllObjects()

        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? self.fileManager.removeItem(at: self.diskCacheURL)
            try? self.fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        }
    }

    /// Returns cache statistics for monitoring
    var cacheStats: (memoryUsed: Int, diskSize: Int, itemCount: Int) {
        let memoryUsed = thumbnailCache.totalCostLimit + previewCache.totalCostLimit
        return (memoryUsed, diskCacheSize, thumbnailCache.countLimit + previewCache.countLimit)
    }

    // MARK: - Private Methods

    private func cacheKey(for itemId: UUID) -> String {
        return itemId.uuidString
    }

    private func diskImageBytes(_ image: CGImage) -> Int {
        return image.bytesPerRow * image.height
    }

    private func resizeImage(_ image: NSImage, maxSize: CGSize) -> CGImage? {
        guard image.isValid else { return nil }

        let originalSize = image.size
        let widthRatio = maxSize.width / originalSize.width
        let heightRatio = maxSize.height / originalSize.height
        let ratio = min(widthRatio, heightRatio)

        guard ratio < 1.0 else {
            // Image is smaller than max size, just convert to CGImage
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        let newSize = CGSize(width: originalSize.width * ratio, height: originalSize.height * ratio)

        let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(newSize.width),
            pixelsHigh: Int(newSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: .alphaFirst,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let rep = bitmapRep else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let drawRect = CGRect(origin: .zero, size: newSize)
        image.draw(in: drawRect)

        NSGraphicsContext.restoreGraphicsState()

        return rep.cgImage
    }

    private func saveToDisk(_ image: CGImage, key: String, type: CacheType) {
        let filename: String
        switch type {
        case .thumbnail:
            filename = "\(key)_thumb.jpg"
        case .preview:
            filename = "\(key)_preview.jpg"
        }

        let url = diskCacheURL.appendingPathComponent(filename)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, kUTTypeJPEG, 1, nil) else {
            return
        }

        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.7,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)

        CGImageDestinationFinalize(destination)
    }

    private func loadFromDisk(key: String, type: CacheType) -> CGImage? {
        let filename: String
        switch type {
        case .thumbnail:
            filename = "\(key)_thumb.jpg"
        case .preview:
            filename = "\(key)_preview.jpg"
        }

        let url = diskCacheURL.appendingPathComponent(filename)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        return cgImage
    }
}

