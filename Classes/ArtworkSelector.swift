//
//  ArtworkSelector.swift
//  Subler
//
//  Created by Damiano Galassi on 04/08/2017.
//

import Cocoa
import MP42Foundation

private protocol ArtworkImageObjectDelegate: AnyObject {
    func reloadItem(_ item: ArtworkImageObject)
}

private class ArtworkImageObject : Equatable {

    static func == (lhs: ArtworkImageObject, rhs: ArtworkImageObject) -> Bool {
        return lhs.source.url == rhs.source.url
    }

    private var data: Data?
    private var version: Int
    private var cancelled: Bool
    private var finished: Bool
    fileprivate let source: Artwork
    private let queue: DispatchQueue
    private weak var delegate: ArtworkImageObjectDelegate?

    init(artwork: Artwork, delegate: ArtworkImageObjectDelegate) {
        self.source = artwork
        self.delegate = delegate
        self.version = 0
        self.cancelled = false
        self.finished = false
        self.queue = DispatchQueue(label: "artworkQueue")
    }

    func cancel() {
        queue.sync {
            cancelled = true
            delegate = nil
        }
    }

    var image: NSImage? {
        if let data = imageRepresentation() {
            return NSImage(data: data)
        } else {
            return nil
        }
    }

    private func imageRepresentation() -> Data? {
        // Get the data outside the main thread
        var startDownload: Bool = false
        queue.sync {
            if self.version == 0 {
                self.version = 1
                startDownload = true
            }
        }

        if startDownload {
            DispatchQueue.global(qos: .userInitiated).async {
                let localData = URLSession.data(from: self.source.thumbURL)
                var localCancelled = false

                self.queue.sync {
                    self.data = localData
                    self.version = 2
                    self.finished = true
                    localCancelled = self.cancelled
                }

                // We got the data, tell the controller to update the view
                if localCancelled == false {
                    DispatchQueue.main.async {
                        self.delegate?.reloadItem(self)
                    }
                }
            }
        }

        var localData: Data? = nil

        queue.sync {
            if let returnData = data {
                localData = returnData
            }
        }
        return localData
    }

    var hasFinishedLoading: Bool {
        return queue.sync { finished }
    }

    var imageTitle: String {
        return source.service
    }

    var imageSubtitle: String {
        return source.type.description
    }

}

protocol ArtworkSelectorControllerDelegate: AnyObject {
    func didAddArtworks(metadata: MetadataResult)
}

class ArtworkCollectionView : NSCollectionView {
    override func keyDown(with event: NSEvent) {
        guard let key = event.charactersIgnoringModifiers?.utf16.first else { super.keyDown(with: event); return }

        if key == NSEnterCharacter || key == NSCarriageReturnCharacter {
            nextResponder?.keyDown(with: event)
        } else if selectionIndexPaths.isEmpty {
            if key == NSRightArrowFunctionKey || key == NSDownArrowFunctionKey {
                let indexPathSet = Set([IndexPath(item: 0, section: 0)])
                animator().selectItems(at: indexPathSet, scrollPosition: .bottom)
                delegate?.collectionView?(self, didSelectItemsAt: indexPathSet)
            } else if key == NSLeftArrowFunctionKey || key == NSUpArrowFunctionKey  {
                let numberOfItems = dataSource?.collectionView(self, numberOfItemsInSection: 0) ?? 1
                let indexPathSet = Set([IndexPath(item: numberOfItems - 1, section: 0)])
                animator().selectItems(at: indexPathSet, scrollPosition: .bottom)
                delegate?.collectionView?(self, didSelectItemsAt: indexPathSet)
            } else {
                super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }
}

final class ArtworkSelectorController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate, ArtworkImageObjectDelegate {

    @IBOutlet var imageBrowser: NSCollectionView!
    @IBOutlet var slider: NSSlider!
    @IBOutlet var addArtworkButton: NSButton!
    @IBOutlet var loadMoreArtworkButton: NSButton!
    @IBOutlet var sortButton: NSButton!
    @IBOutlet var filterButton: NSButton!

    @IBOutlet var progress: NSProgressIndicator!
    @IBOutlet var progressText: NSTextField!

    private let allArtworks: [Artwork]
    private var artworks: [ArtworkImageObject]
    private let standardSize = NSSize(width: 154, height: 192)
    private let metadata: MetadataResult
    private var itemsPerProvider = 5
    private var failedThumbnailURLs = Set<URL>()

    private enum ArtworkSort: String {
        case original
        case quality
    }

    private var artworkSort: ArtworkSort {
        get { ArtworkSort(rawValue: UserDefaults.standard.string(forKey: "SBArtworkSelectorSort") ?? "") ?? .original }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "SBArtworkSelectorSort") }
    }

    private var sortAscending: Bool {
        get { UserDefaults.standard.object(forKey: "SBArtworkSelectorSortAscending") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "SBArtworkSelectorSortAscending") }
    }

    private var hideEmptyThumbnails: Bool {
        get { UserDefaults.standard.object(forKey: "SBArtworkSelectorHideEmptyThumbnails") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "SBArtworkSelectorHideEmptyThumbnails") }
    }

    private weak var delegate: ArtworkSelectorControllerDelegate?

    // MARK: UI State
    private enum ArtworkSearchState {
        case none
        case downloading
        case closing
    }

    private var state: ArtworkSearchState = .none

    // MARK: - Init
    init(metadata: MetadataResult, delegate: ArtworkSelectorControllerDelegate) {
        self.delegate = delegate
        self.allArtworks = metadata.remoteArtworks
        self.artworks = []
        self.metadata = metadata
        super.init(nibName: nil, bundle: nil)
    }

    required public init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        imageBrowser.delegate = nil
        imageBrowser.dataSource = nil

        for artwork in artworks {
            artwork.cancel()
        }
    }

    override public var nibName: NSNib.Name? {
        return "ArtworkSelector"
    }

    // MARK: - Load images
    override public func viewDidLoad() {
        super.viewDidLoad()

        view.wantsLayer = true

        imageBrowser.register(ArtworkSelectorViewItem.self, forItemWithIdentifier: ArtworkSelectorController.itemView)
        configureMenus()
        rebuildArtworks()

        let type = metadata.mediaKind.description

        if let defaultService = UserDefaults.standard.string(forKey: "SBArtworkSelectorDefaultService|\(type.description)"),
            let defaultType = ArtworkType(rawValue: UserDefaults.standard.integer(forKey: "SBArtworkSelectorDefaultType|\(type.description)")),
            let defaultSize = ArtworkSize(rawValue: UserDefaults.standard.integer(forKey: "SBArtworkSelectorDefaultSize|\(type.description)")){
            selectArtwork(type: defaultType, size: defaultSize, service: defaultService)
        }

        updateUI()
    }

    override func viewWillAppear() {
        let zoomValue = Prefs.artworkSelectorZoomLevel
        setZoomValue(zoomValue)
        slider.floatValue = zoomValue
    }

    @IBAction func loadMoreArtwork(_ sender: Any) {
        itemsPerProvider += 5
        rebuildArtworks()
    }

    @IBAction func showSortMenu(_ sender: NSButton) {
        sortButton.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @IBAction func showFilterMenu(_ sender: NSButton) {
        rebuildFilterMenu()
        filterButton.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    // MARK: - User Interface

    private func setZoomValue(_ newZoomValue: Float) {
        if let layout = imageBrowser.collectionViewLayout as? NSCollectionViewFlowLayout {
            if newZoomValue == 50 {
                layout.itemSize = standardSize
            } else if newZoomValue < 50 {
                let zoomValue = (CGFloat(newZoomValue) + 50) / 100
                layout.itemSize = NSSize(width: Int(standardSize.width * zoomValue),
                                         height: Int((standardSize.height - 32) * zoomValue + 32))

            } else {
                let zoomValue = pow((CGFloat(newZoomValue) + 50) / 100, 2.4)
                layout.itemSize = NSSize(width: Int(standardSize.width * zoomValue),
                                         height: Int((standardSize.height - 32) * zoomValue + 32))
            }
        }
    }

    @IBAction func zoomSliderDidChange(_ sender: Any) {
        setZoomValue(slider.floatValue)
        Prefs.artworkSelectorZoomLevel = slider.floatValue
    }

    fileprivate func reloadItem(_ item: ArtworkImageObject) {
        let selectionIndexPaths = imageBrowser.selectionIndexPaths

        if hideEmptyThumbnails, item.hasFinishedLoading, item.image == nil {
            failedThumbnailURLs.insert(item.source.thumbURL)
            rebuildArtworks()
            return
        }

        if let index = artworks.firstIndex(of: item) {
            let indexPath = IndexPath(item: index, section: 0)
            imageBrowser.reloadItems(at: [indexPath])
        }

        imageBrowser.selectionIndexPaths = selectionIndexPaths
    }

    private func selectArtwork(at index: Int) {
        guard artworks.indices.contains(index), imageBrowser.numberOfItems(inSection: 0) > index else {
            addArtworkButton.isEnabled = false
            return
        }
        let indexPath = IndexPath(item: index, section: 0)
        imageBrowser.selectItems(at: [indexPath], scrollPosition: .top)
        addArtworkButton.isEnabled = imageBrowser.selectionIndexPaths.isEmpty == false
    }

    private func scheduleArtworkSelection(at index: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.artworks.indices.contains(index),
                  self.imageBrowser.numberOfItems(inSection: 0) > index else {
                self?.addArtworkButton.isEnabled = false
                return
            }
            self.selectArtwork(at: index)
        }
    }

    private func configureMenus() {
        sortButton.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "Sort artwork")
        sortButton.imagePosition = .imageOnly
        filterButton.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle", accessibilityDescription: "Filter artwork")
        filterButton.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Default", action: #selector(setSort(_:)), representedObject: ArtworkSort.original.rawValue, state: artworkSort == .original))
        menu.addItem(menuItem(title: "Quality", action: #selector(setSort(_:)), representedObject: ArtworkSort.quality.rawValue, state: artworkSort == .quality))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Ascending", action: #selector(setSortDirection(_:)), representedObject: true, state: sortAscending))
        menu.addItem(menuItem(title: "Descending", action: #selector(setSortDirection(_:)), representedObject: false, state: !sortAscending))
        sortButton.menu = menu
        rebuildFilterMenu()
    }

    private func menuItem(title: String, action: Selector, representedObject: Any? = nil, state: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.state = state ? .on : .off
        return item
    }

    private func providerKey(_ service: String) -> String {
        switch service {
        case "TheMovieDB": return "TMDB"
        case "TheTVDB": return "TVDB"
        case "Apple TV": return "Apple"
        case "iTunes Store": return "iTunes"
        default: return service
        }
    }

    private func providerServices() -> [String] {
        var providers = Array(Set(allArtworks.map { providerKey($0.service) }))
        let primary = allArtworks.first.map { providerKey($0.service) }
        providers.sort { lhs, rhs in
            if lhs == primary { return true }
            if rhs == primary { return false }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
        return providers
    }

    private func filterKey(_ group: String, _ value: String) -> String {
        return "SBArtworkSelectorFilter|\(group)|\(value)"
    }

    private func isFilterEnabled(_ group: String, _ value: String) -> Bool {
        let key = filterKey(group, value)
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private func rebuildFilterMenu() {
        let menu = NSMenu()
        let typeItem = NSMenuItem(title: "Artwork Type", action: nil, keyEquivalent: "")
        let typeMenu = NSMenu()
        for value in ["Poster", "Rectangle", "Square"] {
            typeMenu.addItem(menuItem(title: value, action: #selector(toggleFilter(_:)), representedObject: ["type", value], state: isFilterEnabled("type", value)))
        }
        typeItem.submenu = typeMenu
        menu.addItem(typeItem)

        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for provider in providerServices() {
            providerMenu.addItem(menuItem(title: provider, action: #selector(toggleFilter(_:)), representedObject: ["provider", provider], state: isFilterEnabled("provider", provider)))
        }
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Hide Empty Thumbnails", action: #selector(toggleEmptyThumbnails(_:)), state: hideEmptyThumbnails))
        filterButton.menu = menu
    }

    @objc private func setSort(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String, let sort = ArtworkSort(rawValue: value) else { return }
        artworkSort = sort
        configureMenus()
        rebuildArtworks()
    }

    @objc private func setSortDirection(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Bool else { return }
        sortAscending = value
        configureMenus()
        rebuildArtworks()
    }

    @objc private func toggleFilter(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String], values.count == 2 else { return }
        let key = filterKey(values[0], values[1])
        UserDefaults.standard.set(!isFilterEnabled(values[0], values[1]), forKey: key)
        rebuildFilterMenu()
        rebuildArtworks()
    }

    @objc private func toggleEmptyThumbnails(_ sender: NSMenuItem) {
        hideEmptyThumbnails.toggle()
        rebuildFilterMenu()
        rebuildArtworks()
    }

    private func artworkShape(_ artwork: Artwork) -> String {
        // Prefer real dimensions when a provider supplies them. Size enums such
        // as .high/.medium describe quality for some providers, not aspect ratio.
        if let width = artwork.width, let height = artwork.height, width > 0, height > 0 {
            if width == height { return "Square" }
            return width > height ? "Rectangle" : "Poster"
        }

        switch artwork.size {
        case .square:
            return "Square"
        case .rectangle, .fullscreen, .widescreen:
            return "Rectangle"
        default:
            return "Poster"
        }
    }

    private func artworkTypeEnabled(_ artwork: Artwork) -> Bool {
        return isFilterEnabled("type", artworkShape(artwork))
    }

    private func qualityRank(_ artwork: Artwork) -> Int64 {
        if let width = artwork.width, let height = artwork.height {
            return Int64(width) * Int64(height)
        }
        switch artwork.size {
        case .maxres: return 4
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        default: return 0
        }
    }

    private func eligibleArtworks() -> [Artwork] {
        var result = allArtworks.filter { artwork in
            let provider = providerKey(artwork.service)
            return isFilterEnabled("provider", provider) && artworkTypeEnabled(artwork) && !failedThumbnailURLs.contains(artwork.thumbURL)
        }
        return result
    }

    private func artworkDefaultRank(_ artwork: Artwork) -> (Int, Int) {
        // Default ordering favors provider-native poster artwork before the
        // season/episode/backdrop images that are often rectangular.
        let typeRank: Int
        switch artwork.type {
        case .poster:
            typeRank = 0
        case .season:
            typeRank = 1
        case .episode:
            typeRank = 2
        case .backdrop:
            typeRank = 3
        default:
            typeRank = 4
        }

        let shapeRank: Int
        switch artworkShape(artwork) {
        case "Square":
            shapeRank = 2
        case "Rectangle":
            shapeRank = 1
        default:
            shapeRank = 0
        }
        return (typeRank, shapeRank)
    }

    private func balancedArtworks() -> [Artwork] {
        let eligible = eligibleArtworks()
        var result: [Artwork] = []
        for provider in providerServices() where isFilterEnabled("provider", provider) {
            let matches = eligible.filter { providerKey($0.service) == provider }
            let ordered: [Artwork]
            ordered = matches.enumerated().sorted { lhs, rhs in
                if artworkSort == .original {
                    let leftRank = artworkDefaultRank(lhs.element)
                    let rightRank = artworkDefaultRank(rhs.element)
                    if leftRank.0 != rightRank.0 { return leftRank.0 < rightRank.0 }
                    if leftRank.1 != rightRank.1 { return leftRank.1 < rightRank.1 }
                    return sortAscending ? lhs.offset < rhs.offset : lhs.offset > rhs.offset
                } else {
                    let leftQuality = qualityRank(lhs.element)
                    let rightQuality = qualityRank(rhs.element)
                    if leftQuality != rightQuality {
                        return sortAscending ? leftQuality < rightQuality : leftQuality > rightQuality
                    }
                    return sortAscending ? lhs.offset < rhs.offset : lhs.offset > rhs.offset
                }
            }.map(\.element)
            result.append(contentsOf: ordered.prefix(itemsPerProvider))
        }
        return result
    }

    private func rebuildArtworks() {
        let selectedURLs = Set(selectedArtworks().map { $0.source.url })
        for artwork in artworks { artwork.cancel() }
        artworks = balancedArtworks().map { ArtworkImageObject(artwork: $0, delegate: self) }
        imageBrowser.reloadData()
        loadMoreArtworkButton.isEnabled = providerServices().contains { provider in
            eligibleArtworks().filter { providerKey($0.service) == provider }.count > itemsPerProvider
        }
        let selection = Set(artworks.enumerated().compactMap { selectedURLs.contains($0.element.source.url) ? IndexPath(item: $0.offset, section: 0) : nil })
        imageBrowser.selectionIndexPaths = selection
        if selection.isEmpty, artworks.isEmpty == false { scheduleArtworkSelection(at: 0) }
    }

    private func selectArtwork(type: ArtworkType, size: ArtworkSize, service: String) {
        if let artwork = (artworks.filter { $0.source.type == type && $0.source.size == size && $0.source.service == service } as [ArtworkImageObject]).first,
            let index = artworks.firstIndex(of: artwork) {
            scheduleArtworkSelection(at: index)
        }
        else if let artwork = (artworks.filter { $0.source.type == type && $0.source.size == size } as [ArtworkImageObject]).first,
            let index = artworks.firstIndex(of: artwork) {
            scheduleArtworkSelection(at: index)
        }
        else if let artwork = (artworks.filter { $0.source.type == type } as [ArtworkImageObject]).first,
            let index = artworks.firstIndex(of: artwork) {
            scheduleArtworkSelection(at: index)
        }
    }

    private func selectedArtworks() -> [ArtworkImageObject] {
        return imageBrowser.selectionIndexPaths.compactMap { indexPath in
            artworks.indices.contains(indexPath.item) ? artworks[indexPath.item] : nil
        }
    }

    // MARK - UI state

    private func disableUI() {
        [slider, addArtworkButton, loadMoreArtworkButton, sortButton, filterButton].forEach { $0.isEnabled = false }
        imageBrowser.isSelectable = false
    }

    private func startProgressReport() {
        progress.startAnimation(self)
        progress.isHidden = false
        switch state {
        case .downloading:
            progressText.stringValue = NSLocalizedString("Downloading artworks…", comment: "")
        case .closing: break
        default: break
        }
        progressText.isHidden = false
    }

    private func stopProgressReport() {
        progress.stopAnimation(self)
        progress.isHidden = true
        progressText.isHidden = true
    }

    private func updateUI() {
        switch state {
        case .none:
            stopProgressReport()
        case .downloading:
            disableUI()
            startProgressReport()
            loadMoreArtworkButton.isHidden = true
        case .closing:
            disableUI()
            loadMoreArtworkButton.isHidden = true
            stopProgressReport()
        }
    }

    // MARK: - Finishing Up

    private func load(artworks: [Artwork]) {
        switch state {
        case .none:

            state = .downloading
            updateUI()

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let downloadedArtworks = artworks.compactMap { (artwork) -> MP42Image? in
                    if let data = URLSession.data(from: artwork.url) {
                        return MP42Image(data: data, type: MP42_ART_JPEG)
                    } else if artwork.service == iTunesStore().name, // Hack, download smaller iTunes version if big iTunes version is not available
                        let data = URLSession.data(from: artwork.url.deletingPathExtension().appendingPathExtension("600x600bb.jpg")) {
                        return MP42Image(data: data, type: MP42_ART_JPEG)
                    } else {
                        return nil
                    }
                }
                DispatchQueue.main.async {
                    self?.loadDone(images: downloadedArtworks)
                }
            }
        default:
            break
        }
    }

    private func loadDone(images: [MP42Image]) {
        self.state = .closing
        self.metadata.artworks.append(contentsOf: images)
        self.delegate?.didAddArtworks(metadata: self.metadata)
        self.updateUI()
    }

    @IBAction func addArtwork(_ sender: Any) {
        load(artworks: selectedArtworks().map { $0.source })
    }

    @IBAction func addNoArtwork(_ sender: Any) {
        delegate?.didAddArtworks(metadata: metadata)
    }

    // MARK: - Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        return artworks.count
    }

    static let itemView = NSUserInterfaceItemIdentifier(rawValue: "ArtworkSelectorViewItem")

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: ArtworkSelectorController.itemView, for: indexPath)
        guard let collectionViewItem = item as? ArtworkSelectorViewItem, let index = indexPath.last else { return item }

        let artwork = artworks[index]

        collectionViewItem.title = artwork.imageTitle
        collectionViewItem.subtitle = artwork.imageSubtitle
        collectionViewItem.image = artwork.image

        collectionViewItem.doubleAction = #selector(addArtwork)
        collectionViewItem.target = self

        return collectionViewItem
    }

    // MARK: - Delegate

    private func updateSelection() {
        addArtworkButton.isEnabled = imageBrowser.selectionIndexes.isEmpty == false
        if let artwork = selectedArtworks().first {
            let type = metadata.mediaKind.description
            UserDefaults.standard.set(artwork.source.size.rawValue, forKey: "SBArtworkSelectorDefaultSize|\(type.description)")
            UserDefaults.standard.set(artwork.source.type.rawValue, forKey: "SBArtworkSelectorDefaultType|\(type.description)")
            UserDefaults.standard.set(artwork.source.service, forKey: "SBArtworkSelectorDefaultService|\(type.description)")
        }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateSelection()
    }
}
