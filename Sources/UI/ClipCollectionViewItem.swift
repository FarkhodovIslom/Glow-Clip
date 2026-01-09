import AppKit

/// Custom collection view item for displaying clipboard entries
@MainActor
final class ClipCollectionViewItem: NSCollectionViewItem {

    // MARK: - Constants

    static let identifier = NSUserInterfaceItemIdentifier("ClipCollectionViewItem")

    private enum Layout {
        static let cornerRadius: CGFloat = 8
        static let padding: CGFloat = 12
        static let iconSize: CGFloat = 24
        static let previewImageHeight: CGFloat = 80
        static let borderWidth: CGFloat = 1
    }

    // MARK: - UI Components

    private let containerView: NSView = {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = Layout.cornerRadius
        view.layer?.masksToBounds = true
        return view
    }()

    private let typeIconView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .secondaryLabelColor
        return imageView
    }()

    private let previewLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        label.cell?.truncatesLastVisibleLine = true
        return label
    }()

    private let previewImageView: NSImageView = {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 4
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        return imageView
    }()

    private let dateLabel: NSTextField = {
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        return label
    }()

    private let pinIndicator: NSImageView = {
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        imageView.contentTintColor = .systemOrange
        imageView.isHidden = true
        return imageView
    }()

    // MARK: - Properties

    private var currentItem: ClipItem?

    private lazy var dateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        setupViews()
        setupConstraints()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        previewLabel.stringValue = ""
        previewImageView.image = nil
        previewImageView.isHidden = true
        previewLabel.isHidden = false
        pinIndicator.isHidden = true
        currentItem = nil
    }

    override var isSelected: Bool {
        didSet {
            updateAppearance()
        }
    }

    // MARK: - Setup

    private func setupViews() {
        view.addSubview(containerView)
        containerView.addSubview(typeIconView)
        containerView.addSubview(previewLabel)
        containerView.addSubview(previewImageView)
        containerView.addSubview(dateLabel)
        containerView.addSubview(pinIndicator)

        previewImageView.isHidden = true
    }

    private func setupConstraints() {
        containerView.translatesAutoresizingMaskIntoConstraints = false
        typeIconView.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewImageView.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        pinIndicator.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            // Container fills the view
            containerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerView.topAnchor.constraint(equalTo: view.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Type icon
            typeIconView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Layout.padding),
            typeIconView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Layout.padding),
            typeIconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            typeIconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),

            // Pin indicator
            pinIndicator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Layout.padding),
            pinIndicator.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Layout.padding),
            pinIndicator.widthAnchor.constraint(equalToConstant: 16),
            pinIndicator.heightAnchor.constraint(equalToConstant: 16),

            // Preview label
            previewLabel.leadingAnchor.constraint(equalTo: typeIconView.trailingAnchor, constant: 8),
            previewLabel.trailingAnchor.constraint(equalTo: pinIndicator.leadingAnchor, constant: -8),
            previewLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: Layout.padding),

            // Preview image
            previewImageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Layout.padding),
            previewImageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -Layout.padding),
            previewImageView.topAnchor.constraint(equalTo: typeIconView.bottomAnchor, constant: 8),
            previewImageView.heightAnchor.constraint(equalToConstant: Layout.previewImageHeight),

            // Date label
            dateLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: Layout.padding),
            dateLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -Layout.padding),
        ])
    }

    private func updateAppearance() {
        if isSelected {
            containerView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
            containerView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            containerView.layer?.borderWidth = Layout.borderWidth
        } else {
            containerView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            containerView.layer?.borderColor = NSColor.separatorColor.cgColor
            containerView.layer?.borderWidth = Layout.borderWidth
        }
    }

    // MARK: - Configuration

    func configure(with item: ClipItem) {
        currentItem = item

        // Configure type icon
        let symbolName: String
        switch item.type {
        case .text:
            symbolName = "doc.text"
        case .image:
            symbolName = "photo"
        case .file:
            symbolName = "doc"
        }
        typeIconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.type.displayName)

        // Configure pin indicator
        pinIndicator.isHidden = !item.pinned

        // Configure date
        dateLabel.stringValue = dateFormatter.localizedString(for: item.date, relativeTo: Date())

        // Configure preview based on type
        switch item.type {
        case .text:
            configureTextPreview(item)

        case .image:
            configureImagePreview(item)

        case .file:
            configureFilePreview(item)
        }
    }

    private func configureTextPreview(_ item: ClipItem) {
        previewLabel.isHidden = false
        previewImageView.isHidden = true
        previewLabel.stringValue = item.displayPreview(maxLength: 200)
    }

    private func configureImagePreview(_ item: ClipItem) {
        previewLabel.isHidden = true
        previewImageView.isHidden = false

        // Load image asynchronously
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let content = ClipStorage.shared.content(for: item) as? NSImage else {
                return
            }

            DispatchQueue.main.async {
                guard self?.currentItem?.id == item.id else { return }
                self?.previewImageView.image = content
            }
        }
    }

    private func configureFilePreview(_ item: ClipItem) {
        previewLabel.isHidden = false
        previewImageView.isHidden = true
        previewLabel.stringValue = item.originalFilename ?? "File"

        // Try to get file icon
        if let urls = ClipStorage.shared.content(for: item) as? [URL],
           let firstURL = urls.first {
            let icon = NSWorkspace.shared.icon(forFile: firstURL.path)
            icon.size = NSSize(width: Layout.iconSize, height: Layout.iconSize)
            typeIconView.image = icon
        }
    }
}
