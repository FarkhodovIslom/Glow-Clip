import Foundation
import AppKit
import os.log

/// Centralized cache management with automatic cleanup and memory pressure handling
final class CacheManager: @unchecked Sendable {

    // MARK: - Singleton

    static let shared = CacheManager()

    // MARK: - Properties

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "CacheManager")

    private var memoryPressureObserver: NSObjectProtocol?
    private var appLifecycleObserver: NSObjectProtocol?

    private let maxMemoryUsagePercent: Double = 0.25 // Use max 25% of available RAM

    // MARK: - Initialization

    private init() {
        setupObservers()
        logger.info("CacheManager initialized")
    }

    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = appLifecycleObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupObservers() {
        // Listen for app becoming inactive (good time to clear caches)
        appLifecycleObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performCleanup()
            self?.logger.debug("App inactive - performed cache cleanup")
        }

        // Listen for memory pressure via app lifecycle
        // On macOS, we use app termination and deactivation as cleanup triggers
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.performCleanup()
            self?.logger.debug("App terminating - performed cache cleanup")
        }
    }

    // MARK: - Public Interface

    /// Performs comprehensive cache cleanup
    func performCleanup() {
        ImageCache.shared.clearAllCaches()
        clearUrlCache()
        logger.info("Cache cleanup completed")
    }

    /// Handles memory warning by aggressively reducing cache sizes
    func handleMemoryWarning() {
        logger.warning("Memory warning received - reducing cache sizes")

        // Clear all image caches
        ImageCache.shared.clearAllCaches()

        // Force garbage collection hint
        DispatchQueue.main.async {
            self.performCleanup()
        }
    }

    /// Returns current memory usage in bytes
    func getMemoryUsage() -> (used: Int64, available: Int64, percentUsed: Double) {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }

        let usedMemory = result == KERN_SUCCESS ? Int64(info.resident_size) : 0

        // Get total system memory
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        let availableMemory = totalMemory - UInt64(usedMemory)
        let percentUsed = Double(usedMemory) / Double(totalMemory)

        return (usedMemory, Int64(availableMemory), percentUsed)
    }

    /// Checks if memory usage is critical and returns true if cleanup is needed
    func shouldCleanup() -> Bool {
        let usage = getMemoryUsage()
        return usage.percentUsed > maxMemoryUsagePercent
    }

    /// Logs current cache statistics
    func logStats() {
        let memory = getMemoryUsage()
        let imageCacheStats = ImageCache.shared.cacheStats

        logger.info("Memory: \(memory.used / 1_000_000)MB used, \(memory.percentUsed * 100)%")
        logger.info("Image cache: \(imageCacheStats.memoryUsed / 1_000_000)MB memory, \(imageCacheStats.diskSize / 1_000_000)MB disk")
    }

    /// Clears URL cache if used anywhere
    func clearUrlCache() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cacheDir = cacheDir {
            let urlCacheDir = cacheDir.appendingPathComponent("Cache.db")
            try? FileManager.default.removeItem(at: urlCacheDir)
        }
    }

    /// Returns formatted memory usage string for debugging
    var memoryUsageDescription: String {
        let usage = getMemoryUsage()
        return String(format: "Memory: %.1fMB / %.1fMB (%.1f%%)",
                      Double(usage.used) / 1_000_000,
                      Double(ProcessInfo.processInfo.physicalMemory) / 1_000_000,
                      usage.percentUsed * 100)
    }
}

// MARK: - Import for memory info

import Foundation

