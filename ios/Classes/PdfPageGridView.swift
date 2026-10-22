import PDFKit
import UIKit

final class PdfPageGridView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onPageSelected: ((Int) -> Void)?
    var onPageChanged: (() -> Void)?
    var onPaint: ((Int) -> Void)?
    var onError: (() -> Void)?
    private(set) var columns = 3
    private(set) var spacing: Double = 8
    private let document: PDFDocument
    private let renderer: PdfThumbnailRenderer
    private let collection: UICollectionView
    private let cache = NSCache<NSNumber, UIImage>()
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var operations: [Int: Operation] = [:]
    private var lastWidth: CGFloat = 0
    private var maxPixels = 4194304
    private var disposed = false

    init(frame: CGRect, document: PDFDocument) {
        self.document = document
        renderer = PdfThumbnailRenderer(url: document.documentURL)
        collection = UICollectionView(
            frame: CGRect(origin: .zero, size: frame.size),
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        super.init(frame: frame)
        cache.totalCostLimit = 32 * 1024 * 1024
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.dataSource = self
        collection.delegate = self
        collection.register(PdfPageGridCell.self, forCellWithReuseIdentifier: "page")
        addSubview(collection)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { queue.cancelAllOperations() }

    func configure(columns: Int, spacing: Double, background: UIColor, options: [String: Any]) {
        let limit = document.pageCount >= (options["largeDocumentPageCount"] as? Int ?? 100)
            ? options["largeDocumentMaxCanvasPixels"] : options["maxCanvasPixels"]
        let pixels = max(limit as? Int ?? 4194304, 1)
        let changed = self.columns != columns || self.spacing != spacing || maxPixels != pixels
        self.columns = columns
        self.spacing = spacing
        maxPixels = pixels
        collection.backgroundColor = background
        if let layout = collection.collectionViewLayout as? UICollectionViewFlowLayout {
            layout.minimumInteritemSpacing = spacing
            layout.minimumLineSpacing = spacing
            layout.sectionInset = UIEdgeInsets(top: spacing, left: spacing, bottom: spacing, right: spacing)
        }
        if changed { invalidateThumbnails() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.width != lastWidth {
            lastWidth = bounds.width
            invalidateThumbnails()
        }
    }

    private func invalidateThumbnails() {
        operations.values.forEach { $0.cancel() }
        operations.removeAll()
        cache.removeAllObjects()
        collection.collectionViewLayout.invalidateLayout()
        collection.reloadData()
    }

    func scrollToPage(at index: Int) {
        guard index >= 0, index < document.pageCount else { return }
        layoutIfNeeded()
        collection.layoutIfNeeded()
        collection.scrollToItem(at: IndexPath(item: index, section: 0), at: .centeredVertically, animated: false)
        onPageChanged?()
    }

    func topVisiblePageIndex() -> Int? {
        let rect = CGRect(origin: collection.contentOffset, size: collection.bounds.size)
        let visible = collection.indexPathsForVisibleItems.map(\.item)
        let centered = visible.filter {
            guard let frame = collection.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame else {
                return false
            }
            return rect.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        return centered.min() ?? visible.min()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { onPageChanged?() }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        document.pageCount
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "page", for: indexPath)
        guard let cell = cell as? PdfPageGridCell else { return cell }
        let index = indexPath.item
        if let image = cache.object(forKey: NSNumber(value: index)) {
            cell.imageView.image = image
            DispatchQueue.main.async { [weak self] in self?.onPaint?(index) }
        } else {
            loadThumbnail(index, size: itemSize(index))
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize { itemSize(indexPath.item) }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onPageSelected?(indexPath.item)
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        operations.removeValue(forKey: indexPath.item)?.cancel()
    }

    private func itemSize(_ index: Int) -> CGSize {
        let width = max(floor((collection.bounds.width - spacing * Double(columns + 1)) / Double(columns)), 1)
        guard let page = document.page(at: index) else { return CGSize(width: width, height: width * 1.414) }
        let bounds = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageWidth = rotated ? bounds.height : bounds.width
        let pageHeight = rotated ? bounds.width : bounds.height
        let ratio = pageWidth > 0 ? pageHeight / pageWidth : 1.414
        return CGSize(width: width, height: max(floor(width * ratio), 1))
    }

    private func loadThumbnail(_ index: Int, size: CGSize) {
        guard !disposed, operations[index] == nil else { return }
        let renderer = renderer
        let nativeScale = max(traitCollection.displayScale, 1)
        let scale = min(nativeScale, sqrt(Double(maxPixels) / max(size.width * size.height, 1)))
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            let image = renderer.render(index: index, size: size, scale: scale)
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.disposed, self.operations[index] === operation else { return }
                self.operations[index] = nil
                guard !operation.isCancelled else { return }
                guard let image = image else { self.onError?(); return }
                let result = UIImage(cgImage: image, scale: max(scale, 0.01), orientation: .up)
                self.cache.setObject(result, forKey: NSNumber(value: index), cost: image.bytesPerRow * image.height)
                if let cell = self.collection.cellForItem(at: IndexPath(item: index, section: 0)) as? PdfPageGridCell {
                    cell.imageView.image = result
                    self.onPaint?(index)
                }
            }
        }
        operations[index] = operation
        queue.addOperation(operation)
    }

    func dispose() {
        disposed = true
        queue.cancelAllOperations()
        operations.removeAll()
        cache.removeAllObjects()
        collection.delegate = nil
        onPaint = nil
        onPageChanged = nil
        onPageSelected = nil
        onError = nil
    }
}

private final class PdfThumbnailRenderer {
    private let url: URL?
    private var document: CGPDFDocument?

    init(url: URL?) { self.url = url }

    func render(index: Int, size: CGSize, scale: CGFloat) -> CGImage? {
        if document == nil, let url = url { document = CGPDFDocument(url as CFURL) }
        guard let document = document, index >= 0, index < document.numberOfPages,
              let page = document.page(at: index + 1) else { return nil }
        let width = max(Int(ceil(size.width * scale)), 1)
        let height = max(Int(ceil(size.height * scale)), 1)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.clip(to: page.getBoxRect(.cropBox))
        context.drawPDFPage(page)
        return context.makeImage()
    }
}

private final class PdfPageGridCell: UICollectionViewCell {
    let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .white
        contentView.addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}
