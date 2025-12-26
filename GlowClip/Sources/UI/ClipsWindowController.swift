import AppKit
import os.log

/// Window controller for displaying clipboard history
final class ClipsWindowController: NSWindowController {

    // MARK: - Constants

    private enum Layout {
        static let windowWidth: CGFloat = 400
        static let windowHeight: CGFloat = 500
        static let itemWidth: CGFloat = 360
        static let itemHeight: CGFloat = 100
        static let sectionInset: CGFloat = 20
        static let interItemSpacing: CGFloat = 12
    }

    // MARK: - Properties

    private var items: [ClipItem] = []
    private var collectionView: NSCollectionView!
    private var scrollView: NSScrollView!
    private var emptyStateLabel: NSTextField!

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "GlowClip", category: "ClipsWindow")

    var clipboardWatcher: ClipboardWatcher?

    // MARK: - Initialization

    convenience init() {
        let window = Self.createWindow()
        self.init(window: window)
        setupUI()
        setupNotifications()
        reloadData()
    }

    private static func createWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Glow Clip"
        window.minSize = NSSize(width: 300, height: 400)
        window.center()
        window.isReleasedWhenClosed = false

        // Modern appearance
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.backgroundColor = .windowBackgroundColor

        return window
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Create scroll view
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Create collection view with flow layout
        let flowLayout = NSCollectionViewFlowLayout()
        flowLayout.scrollDirection = .vertical
        flowLayout.itemSize = NSSize(width: Layout.itemWidth, height: Layout.itemHeight)
        flowLayout.minimumInteritemSpacing = Layout.interItemSpacing
        flowLayout.minimumLineSpacing = Layout.interItemSpacing
        flowLayout.sectionInset = NSEdgeInsets(
            top: Layout.sectionInset,
            left: Layout.sectionInset,
            bottom: Layout.sectionInset,
            right: Layout.sectionInset
        )

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false

        collectionView.register(
            ClipCollectionViewItem.self,
            forItemWithIdentifier: ClipCollectionViewItem.identifier
        )

        scrollView.documentView = collectionView

        // Empty state label
        emptyStateLabel = NSTextField(labelWithString: "No clips yet\nCopy something to get started")
        emptyStateLabel.font = .systemFont(ofSize: 15, weight: .medium)
        emptyStateLabel.textColor = .tertiaryLabelColor
        emptyStateLabel.alignment = .center
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.isHidden = true

        contentView.addSubview(scrollView)
        contentView.addSubview(emptyStateLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])

        // Setup context menu
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(copySelectedItem), keyEquivalent: "c")
        menu.addItem(withTitle: "Pin/Unpin", action: #selector(togglePinSelectedItem), keyEquivalent: "p")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Delete", action: #selector(deleteSelectedItem), keyEquivalent: String(Character(UnicodeScalar(NSBackspaceCharacter)!)))
        collectionView.menu = menu
    }

    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(storageDidUpdate),
            name: .clipStorageDidUpdate,
            object: nil
        )
    }

    // MARK: - Data

    func reloadData() {
        items = ClipStorage.shared.allItems()
        collectionView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        let isEmpty = items.isEmpty
        emptyStateLabel.isHidden = !isEmpty
        scrollView.isHidden = isEmpty
    }

    @objc private func storageDidUpdate() {
        reloadData()
    }

    // MARK: - Actions

    @objc private func copySelectedItem() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              indexPath.item < items.count else {
            return
        }

        let item = items[indexPath.item]
        clipboardWatcher?.writeToClipboard(item)

        logger.info("Copied item: \(item.id)")
    }

    @objc private func togglePinSelectedItem() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              indexPath.item < items.count else {
            return
        }

        let item = items[indexPath.item]
        ClipStorage.shared.togglePin(for: item.id)
    }

    @objc private func deleteSelectedItem() {
        guard let indexPath = collectionView.selectionIndexPaths.first,
              indexPath.item < items.count else {
            return
        }

        let item = items[indexPath.item]
        ClipStorage.shared.delete(itemId: item.id)
    }
}

// MARK: - NSCollectionViewDataSource

extension ClipsWindowController: NSCollectionViewDataSource {

    func numberOfSections(in collectionView: NSCollectionView) -> Int {
        return 1
    }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ClipCollectionViewItem.identifier,
            for: indexPath
        )

        guard let clipItem = item as? ClipCollectionViewItem else {
            return item
        }

        if indexPath.item < items.count {
            clipItem.configure(with: items[indexPath.item])
        }

        return clipItem
    }
}

// MARK: - NSCollectionViewDelegate

extension ClipsWindowController: NSCollectionViewDelegate {

    func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        // Selection visual feedback is handled by ClipCollectionViewItem
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension ClipsWindowController: NSCollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        // Calculate width based on collection view width
        let availableWidth = collectionView.bounds.width - (Layout.sectionInset * 2)
        let itemWidth = min(availableWidth, Layout.itemWidth)

        // Adjust height for images
        let item = items[indexPath.item]
        let height: CGFloat = item.type == .image ? 160 : Layout.itemHeight

        return NSSize(width: itemWidth, height: height)
    }
}
