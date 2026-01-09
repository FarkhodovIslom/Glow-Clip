import Foundation

/// Represents the type of clipboard content
enum ClipType: String, Codable, CaseIterable {
    case text
    case image
    case file

    var displayName: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// Represents a single clipboard item stored in the history
struct ClipItem: Identifiable, Codable, Equatable {
    let id: UUID
    let type: ClipType
    let date: Date

    /// Relative path from the clips directory to the stored content
    let path: String

    /// Whether this item is pinned and should not be auto-deleted
    var pinned: Bool

    /// Optional metadata for quick display without loading the file
    var preview: String?

    /// Original filename for file type items
    var originalFilename: String?

    init(
        id: UUID = UUID(),
        type: ClipType,
        date: Date = Date(),
        path: String,
        pinned: Bool = false,
        preview: String? = nil,
        originalFilename: String? = nil
    ) {
        self.id = id
        self.type = type
        self.date = date
        self.path = path
        self.pinned = pinned
        self.preview = preview
        self.originalFilename = originalFilename
    }

    static func == (lhs: ClipItem, rhs: ClipItem) -> Bool {
        lhs.id == rhs.id
    }
}

extension ClipItem {
    /// Returns a truncated preview suitable for display
    func displayPreview(maxLength: Int = 100) -> String {
        switch type {
        case .text:
            guard let preview = preview else { return "Empty text" }
            if preview.count <= maxLength {
                return preview
            }
            return String(preview.prefix(maxLength)) + "…"

        case .image:
            return "Image"

        case .file:
            return originalFilename ?? "File"
        }
    }
}
