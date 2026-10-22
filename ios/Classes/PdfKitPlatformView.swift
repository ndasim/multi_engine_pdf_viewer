import Flutter
import PDFKit
import UIKit

final class PdfKitViewFactory: NSObject, FlutterPlatformViewFactory {
    static let viewType = "multi_engine_pdf_viewer/pdfkit"
    private let messenger: FlutterBinaryMessenger

    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        FlutterStandardMessageCodec.sharedInstance()
    }

    func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        PdfKitPlatformView(
            frame: frame,
            arguments: args as? [String: Any] ?? [:],
            channel: FlutterMethodChannel(
                name: "\(Self.viewType)/\(viewId)", binaryMessenger: messenger
            )
        )
    }
}

// Adapted from feature/pdf_native_ios. Documents used for search and outline parsing
// are separate from the displayed document, avoiding PDFKit's cross-thread locks.
final class PdfKitPlatformView: NSObject, FlutterPlatformView, PDFViewDelegate {
    private let container: UIView
    private let pdfView: FittedPDFView
    private let channel: FlutterMethodChannel
    private let arguments: [String: Any]
    private var taps: PdfKitTapHandler?
    private var grid: PdfPageGridView?
    private var pageObserver: NSObjectProtocol?
    private var openResult: FlutterResult?
    private var documentURL: URL?
    private var targets: [Int: [PdfTapTarget]] = [:]
    private var outlineTargets: [[Int]: PdfDestinationTarget] = [:]
    private var options: [String: Any]
    private var disposed = false
    private var opened = false
    private var firstPaintSent = false
    private var lastPage: Int?
    // PDFKit may call a preceding, taller page current even when a short target page is visible.
    // Keep an explicit navigation target until the user starts scrolling.
    private var navigationPage: Int? {
        didSet { pdfView.preferredPageIndex = navigationPage }
    }
    private var navigating = false
    private var searchId = 0
    private var searching = false
    private var matches: [PDFSelection] = []
    private var currentMatch: Int?
    private let searchQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(frame: CGRect, arguments: [String: Any], channel: FlutterMethodChannel) {
        container = UIView(frame: frame)
        pdfView = FittedPDFView(frame: CGRect(origin: .zero, size: frame.size))
        self.arguments = arguments
        options = arguments
        self.channel = channel
        super.init()
        pdfView.delegate = self
        pdfView.enableDataDetectors = false
        pdfView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = false
        pdfView.isHidden = true
        container.addSubview(pdfView)
        taps = PdfKitTapHandler(
            pdfView: pdfView,
            target: { [weak self] point in self?.target(at: point) },
            action: { [weak self] action in self?.perform(action) },
            pageTap: { [weak self] page in self?.send("onPageTap", page) },
            scroll: { [weak self] in
                self?.navigationPage = nil
                self?.pageChanged()
            }
        )
        pdfView.onPaint = { [weak self] page in self?.reportPaint(page) }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: pdfView, queue: .main
        ) { [weak self] _ in self?.pageChanged() }
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self, !self.disposed else {
                result(FlutterError(code: "pdfkit-disposed", message: "PDFKit view disposed.", details: nil))
                return
            }
            self.handle(call, result: result)
        }
        applyOptions()
    }

    deinit {
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
        searchQueue.cancelAllOperations()
        channel.setMethodCallHandler(nil)
    }

    func view() -> UIView { container }

    private func send(_ method: String, _ value: Any? = nil) {
        if !disposed { channel.invokeMethod(method, arguments: value) }
    }

    private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "open":
            guard !opened, openResult == nil,
                  let path = arguments["filePath"] as? String, path.hasPrefix("/") else {
                invalidArguments(result)
                return
            }
            openResult = result
            load(URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath())
        case "configure":
            guard let options = call.arguments as? [String: Any],
                  let columns = options["columns"] as? Int, columns > 0,
                  let margin = options["margin"] as? Double, margin.isFinite, margin >= 0 else {
                invalidArguments(result)
                return
            }
            self.options = options
            applyOptions()
            result(nil)
        case "goToPage":
            guard let number = call.arguments as? Int else { invalidArguments(result); return }
            goToPage(number)
            result(nil)
        case "getOutline":
            loadOutline(result)
        case "goToOutline":
            guard let path = call.arguments as? [Int], path.allSatisfy({ $0 >= 0 }) else {
                invalidArguments(result)
                return
            }
            if let target = outlineTargets[path] {
                closeGrid()
                navigate(target)
            }
            result(nil)
        case "search":
            guard let args = call.arguments as? [String: Any],
                  let query = args["query"] as? String, let id = args["searchId"] as? Int else {
                invalidArguments(result)
                return
            }
            startSearch(query, id: id)
            result(nil)
        case "nextSearchMatch":
            selectMatch((currentMatch ?? -1) + 1)
            result(nil)
        case "previousSearchMatch":
            selectMatch((currentMatch ?? matches.count) - 1)
            result(nil)
        case "dispose":
            dispose()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func invalidArguments(_ result: FlutterResult) {
        result(FlutterError(code: "pdfkit-invalid-arguments", message: "Invalid PDFKit arguments.", details: nil))
    }

    private func load(_ url: URL) {
        documentURL = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let document = PDFDocument(url: url)
            var targets: [Int: [PdfTapTarget]] = [:]
            if let document = document, !document.isLocked {
                for index in 0..<document.pageCount {
                    guard self != nil else { return }
                    guard let page = document.page(at: index) else { continue }
                    _ = page.bounds(for: .cropBox)
                    var pageTargets: [PdfTapTarget] = []
                    for annotation in page.annotations.reversed() {
                        if annotation.shouldDisplay,
                           let action = Self.action(annotation, document: document) {
                            pageTargets.append(PdfTapTarget(bounds: annotation.bounds, action: action))
                        }
                        // PDFKit must never open URLs, remote documents or execute PDF actions itself.
                        annotation.action = nil
                        annotation.destination = nil
                        annotation.url = nil
                    }
                    targets[index] = pageTargets
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.disposed else { return }
                guard let document = document, document.pageCount > 0, !document.isLocked else {
                    let code = document?.isLocked == true ? "pdfkit-password-required" : "pdfkit-invalid-document"
                    self.openResult?(FlutterError(code: code, message: "Unable to open PDF document.", details: nil))
                    self.openResult = nil
                    return
                }
                self.targets = targets
                self.pdfView.initialPageIndex = min(
                    max((self.arguments["initialPage"] as? Int ?? 1) - 1, 0), document.pageCount - 1
                )
                self.navigationPage = self.pdfView.initialPageIndex
                self.pdfView.onFirstDisplay = { [weak self] in self?.completeOpen() }
                self.pdfView.document = document
                self.applyOptions()
            }
        }
    }

    private func completeOpen() {
        guard !disposed, let document = pdfView.document else { return }
        opened = true
        pdfView.isHidden = false
        applyOptions()
        let page = currentPageNumber
        lastPage = page
        openResult?(["pageCount": document.pageCount, "pageNumber": page])
        openResult = nil
    }

    private var currentPageNumber: Int {
        if let grid = grid, !grid.isHidden, let index = grid.topVisiblePageIndex() { return index + 1 }
        guard let document = pdfView.document, let page = pdfView.currentPage else { return 1 }
        if let target = navigationPage,
           pdfView.visiblePages.contains(where: { document.index(for: $0) == target }) { return target + 1 }
        let index = document.index(for: page)
        return index == NSNotFound ? 1 : index + 1
    }

    private func pageChanged() {
        guard opened, !navigating else { return }
        let page = currentPageNumber
        guard page != lastPage else { return }
        lastPage = page
        send("onPageChanged", page)
    }

    private func reportPaint(_ page: Int) {
        guard !disposed, !firstPaintSent else { return }
        firstPaintSent = true
        send("onFirstPageRendered", page)
    }

    private func goToPage(_ number: Int) {
        guard let document = pdfView.document, document.pageCount > 0 else { return }
        let index = min(max(number - 1, 0), document.pageCount - 1)
        if let grid = grid, !grid.isHidden {
            grid.scrollToPage(at: index)
        } else if let page = document.page(at: index) {
            navigating = true
            navigationPage = index
            pdfView.go(to: page)
            navigating = false
        }
        pageChanged()
    }

    private func applyOptions() {
        let background = Self.color(options["backgroundColor"], fallback: .lightGray)
        container.backgroundColor = background
        pdfView.backgroundColor = background
        let margin = (options["margin"] as? NSNumber)?.doubleValue ?? 8
        pdfView.pageBreakMargins = UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        let shadow = Self.color(options["pageShadowColor"], fallback: .clear)
        pdfView.pageShadowsEnabled = shadow.cgColor.alpha > 0
        if !matches.isEmpty {
            for (index, selection) in matches.enumerated() {
                selection.color = Self.color(
                    options[index == currentMatch ? "activeMatchColor" : "matchColor"], fallback: .yellow
                )
            }
            pdfView.highlightedSelections = matches
        }
        guard opened, let document = pdfView.document else { return }
        let columns = options["columns"] as? Int ?? 1
        if columns > 1 {
            let current = currentPageNumber - 1
            let grid = self.grid ?? makeGrid(document)
            let changed = grid.columns != columns || grid.spacing != margin
            grid.configure(columns: columns, spacing: margin, background: background, options: options)
            let wasHidden = grid.isHidden
            grid.isHidden = false
            pdfView.isHidden = true
            if wasHidden || changed { grid.scrollToPage(at: current) }
        } else if let grid = grid, !grid.isHidden {
            let index = grid.topVisiblePageIndex()
            grid.isHidden = true
            pdfView.isHidden = false
            pdfView.fitToWidth()
            if let index = index { goToPage(index + 1) }
        }
    }

    private func makeGrid(_ document: PDFDocument) -> PdfPageGridView {
        let grid = PdfPageGridView(frame: container.bounds, document: document)
        grid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        grid.isHidden = true
        grid.onPageSelected = { [weak self] index in self?.send("onPageTap", index + 1) }
        grid.onPageChanged = { [weak self] in self?.pageChanged() }
        grid.onPaint = { [weak self] index in self?.reportPaint(index + 1) }
        grid.onError = { [weak self] in self?.send("onRenderError") }
        container.addSubview(grid)
        self.grid = grid
        return grid
    }

    private func closeGrid() {
        guard let grid = grid, !grid.isHidden else { return }
        grid.isHidden = true
        pdfView.isHidden = false
        options["columns"] = 1
        pdfView.fitToWidth()
        send("onGridClosed")
    }

    private static func color(_ value: Any?, fallback: UIColor) -> UIColor {
        guard let value = value as? NSNumber else { return fallback }
        let bits = value.uint32Value
        return UIColor(
            red: CGFloat((bits >> 16) & 255) / 255,
            green: CGFloat((bits >> 8) & 255) / 255,
            blue: CGFloat(bits & 255) / 255,
            alpha: CGFloat((bits >> 24) & 255) / 255
        )
    }

    private static func action(_ annotation: PDFAnnotation, document: PDFDocument) -> PdfTapAction? {
        if let destination = annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination,
           let target = PdfDestinationTarget(destination, document: document) {
            return .destination(target)
        }
        if let named = annotation.action as? PDFActionNamed {
            if named.name == .nextPage { return .relativePage(1) }
            if named.name == .previousPage { return .relativePage(-1) }
        }
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url,
           let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel"].contains(scheme) {
            return .external(url.absoluteString)
        }
        return nil
    }

    private func target(at point: CGPoint) -> PdfTapAction? {
        guard let document = pdfView.document, let page = pdfView.page(for: point, nearest: false) else { return nil }
        let point = pdfView.convert(point, to: page)
        return targets[document.index(for: page)]?.first(where: { $0.bounds.contains(point) })?.action
    }

    private func perform(_ action: PdfTapAction) {
        switch action {
        case .destination(let target): navigate(target)
        case .relativePage(let offset): goToPage(currentPageNumber + offset)
        case .external(let url): send("onExternalLinkTap", url)
        }
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        guard let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "tel"].contains(scheme) else { return }
        send("onExternalLinkTap", url.absoluteString)
    }

    private func navigate(_ target: PdfDestinationTarget) {
        guard let page = pdfView.document?.page(at: target.pageIndex) else { return }
        let destination = PDFDestination(page: page, at: target.point)
        if target.zoom.isFinite && target.zoom > 0 { destination.zoom = target.zoom }
        navigating = true
        navigationPage = target.pageIndex
        pdfView.go(to: destination)
        navigating = false
        pageChanged()
    }

    private func loadOutline(_ result: @escaping FlutterResult) {
        guard let url = documentURL else { result([]); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var targets: [[Int]: PdfDestinationTarget] = [:]
            var items: [[String: Any]] = []
            let document = PDFDocument(url: url)
            if let document = document {
                if let root = document.outlineRoot {
                    items = Self.outlineChildren(root, path: [], document: document, targets: &targets)
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self, !self.disposed else {
                    result(FlutterError(code: "pdfkit-disposed", message: "PDFKit view disposed.", details: nil))
                    return
                }
                guard document != nil else {
                    result(FlutterError(code: "pdfkit-outline-failed", message: "Unable to read PDF outline.", details: nil))
                    return
                }
                self.outlineTargets = targets
                result(items)
            }
        }
    }

    private static func outlineChildren(
        _ root: PDFOutline, path: [Int], document: PDFDocument,
        targets: inout [[Int]: PdfDestinationTarget]
    ) -> [[String: Any]] {
        (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            let path = path + [index]
            let children = outlineChildren(child, path: path, document: document, targets: &targets)
            var item: [String: Any] = ["title": child.label ?? "", "path": path, "children": children]
            if let destination = child.destination ?? (child.action as? PDFActionGoTo)?.destination,
               let target = PdfDestinationTarget(destination, document: document) {
                targets[path] = target
                item["pageNumber"] = target.pageIndex + 1
                item["destinationPath"] = path
            } else if let descendant = children.first(where: { $0["destinationPath"] != nil }) {
                item["pageNumber"] = descendant["pageNumber"]
                item["destinationPath"] = descendant["destinationPath"]
            }
            return item
        }
    }

    private func startSearch(_ query: String, id: Int) {
        searchQueue.cancelAllOperations()
        searchId = id
        searching = !query.isEmpty
        matches = []
        currentMatch = nil
        pdfView.highlightedSelections = nil
        notifySearch()
        guard !query.isEmpty, let url = documentURL else { return }
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled, let document = PDFDocument(url: url) else {
                DispatchQueue.main.async { [weak self] in self?.finishSearch(id: id, failed: true) }
                return
            }
            var batch: [(Int, NSRange)] = []
            var flushed = false
            var lastFlush = CFAbsoluteTimeGetCurrent()
            func flush() {
                guard !batch.isEmpty else { return }
                let locations = batch
                batch.removeAll()
                flushed = true
                lastFlush = CFAbsoluteTimeGetCurrent()
                DispatchQueue.main.async { [weak self] in self?.appendMatches(locations, id: id) }
            }
            for index in 0..<document.pageCount {
                guard !operation.isCancelled else { return }
                guard let text = document.page(at: index)?.string as NSString? else { continue }
                var remaining = NSRange(location: 0, length: text.length)
                while remaining.length > 0 {
                    guard !operation.isCancelled else { return }
                    let range = text.range(of: query, options: .caseInsensitive, range: remaining)
                    guard range.location != NSNotFound, range.length > 0 else { break }
                    batch.append((index, range))
                    let next = NSMaxRange(range)
                    remaining = NSRange(location: next, length: text.length - next)
                }
                if !flushed || batch.count >= 20 || CFAbsoluteTimeGetCurrent() - lastFlush >= 0.25 { flush() }
            }
            flush()
            DispatchQueue.main.async { [weak self] in self?.finishSearch(id: id, failed: false) }
        }
        searchQueue.addOperation(operation)
    }

    private func appendMatches(_ locations: [(Int, NSRange)], id: Int) {
        guard !disposed, searchId == id, let document = pdfView.document else { return }
        let selections = locations.compactMap { document.page(at: $0.0)?.selection(for: $0.1) }
        selections.forEach { $0.color = Self.color(options["matchColor"], fallback: .yellow) }
        matches.append(contentsOf: selections)
        if currentMatch == nil {
            selectMatch(0)
        } else {
            pdfView.highlightedSelections = matches
            notifySearch()
        }
    }

    private func finishSearch(id: Int, failed: Bool) {
        guard !disposed, searchId == id else { return }
        searching = false
        notifySearch()
        if failed { send("onSearchError") }
    }

    private func selectMatch(_ index: Int) {
        guard !matches.isEmpty else { return }
        let index = (index % matches.count + matches.count) % matches.count
        if let current = currentMatch {
            matches[current].color = Self.color(options["matchColor"], fallback: .yellow)
        }
        currentMatch = index
        matches[index].color = Self.color(options["activeMatchColor"], fallback: .orange)
        closeGrid()
        pdfView.highlightedSelections = matches
        navigating = true
        if let page = matches[index].pages.first, let document = pdfView.document {
            navigationPage = document.index(for: page)
        }
        pdfView.go(to: matches[index])
        navigating = false
        pageChanged()
        notifySearch()
    }

    private func notifySearch() {
        send("onSearchStateChanged", [
            "searchId": searchId,
            "matchCount": matches.count,
            "currentIndex": currentMatch.map { $0 as Any } ?? NSNull(),
            "isSearching": searching
        ])
    }

    private func dispose() {
        guard !disposed else { return }
        disposed = true
        searchQueue.cancelAllOperations()
        searchId += 1
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
        pageObserver = nil
        openResult?(FlutterError(code: "pdfkit-disposed", message: "PDFKit view disposed.", details: nil))
        openResult = nil
        pdfView.onPaint = nil
        pdfView.onFirstDisplay = nil
        grid?.dispose()
        grid?.removeFromSuperview()
        grid = nil
        matches.removeAll()
        targets.removeAll()
        outlineTargets.removeAll()
        pdfView.document = nil
        channel.setMethodCallHandler(nil)
    }
}

private struct PdfDestinationTarget {
    let pageIndex: Int
    let point: CGPoint
    let zoom: CGFloat

    init?(_ destination: PDFDestination, document: PDFDocument) {
        guard let page = destination.page else { return nil }
        let index = document.index(for: page)
        guard index != NSNotFound, index >= 0, index < document.pageCount else { return nil }
        pageIndex = index
        point = destination.point
        zoom = destination.zoom
    }
}

private enum PdfTapAction {
    case destination(PdfDestinationTarget)
    case relativePage(Int)
    case external(String)
}

private struct PdfTapTarget {
    let bounds: CGRect
    let action: PdfTapAction
}

private final class FittedPDFView: PDFView {
    var initialPageIndex: Int?
    var preferredPageIndex: Int?
    var onFirstDisplay: (() -> Void)?
    var onPaint: ((Int) -> Void)?
    private var fittedWidth: CGFloat = 0

    override var document: PDFDocument? {
        didSet {
            fittedWidth = 0
            minScaleFactor = 0.1
            maxScaleFactor = 8
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        let needsFit = document != nil && bounds.width > 0 && bounds.height > 0 && bounds.width != fittedWidth
        let previous = currentPage
        if needsFit { fitToWidth() }
        super.layoutSubviews()
        guard needsFit else { return }
        fitToWidth()
        fittedWidth = bounds.width
        let page = (initialPageIndex ?? preferredPageIndex).flatMap { document?.page(at: $0) } ?? previous
        initialPageIndex = nil
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.document != nil else { return }
            if let page = page { self.go(to: page) }
            let ready = self.onFirstDisplay
            self.onFirstDisplay = nil
            ready?()
        }
    }

    func fitToWidth() {
        let fit = scaleFactorForSizeToFit
        guard fit.isFinite, fit > 0 else { return }
        minScaleFactor = min(0.1, fit)
        maxScaleFactor = max(8, fit)
        scaleFactor = fit
    }

    override func draw(_ page: PDFPage, to context: CGContext) {
        super.draw(page, to: context)
        DispatchQueue.main.async { [weak self, weak page] in
            guard let self = self, let page = page, let document = self.document,
                  !self.isHidden, self.window != nil else { return }
            let index = document.index(for: page)
            if index != NSNotFound { self.onPaint?(index + 1) }
        }
    }

    override func perform(_ action: PDFAction) {
        // All annotation actions are routed through the package's allowlisted tap handler.
    }
}

private final class PdfKitTapHandler: NSObject, UIGestureRecognizerDelegate {
    private weak var pdfView: PDFView?
    private let linkTap = UITapGestureRecognizer()
    private let pageTap = UITapGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private let target: (CGPoint) -> PdfTapAction?
    private let action: (PdfTapAction) -> Void
    private let onPageTap: (Int) -> Void
    private let onScroll: () -> Void

    init(pdfView: PDFView, target: @escaping (CGPoint) -> PdfTapAction?,
         action: @escaping (PdfTapAction) -> Void, pageTap: @escaping (Int) -> Void,
         scroll: @escaping () -> Void) {
        self.pdfView = pdfView
        self.target = target
        self.action = action
        onPageTap = pageTap
        onScroll = scroll
        super.init()
        linkTap.addTarget(self, action: #selector(linkTapped))
        self.pageTap.addTarget(self, action: #selector(pageTapped))
        linkTap.delegate = self
        self.pageTap.delegate = self
        pdfView.addGestureRecognizer(linkTap)
        pdfView.addGestureRecognizer(self.pageTap)
        pan.addTarget(self, action: #selector(panned))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pdfView.addGestureRecognizer(pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pdfView = pdfView else { return false }
        if gestureRecognizer === pan { return true }
        let point = gestureRecognizer.location(in: pdfView)
        return gestureRecognizer === linkTap ? target(point) != nil : target(point) == nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pan || otherGestureRecognizer === pan
    }

    @objc private func panned() {
        if pan.state == .began { onScroll() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === linkTap, let pdfView = pdfView,
              let tap = otherGestureRecognizer as? UITapGestureRecognizer,
              tap !== pageTap, tap.numberOfTapsRequired == 1,
              let view = tap.view else { return false }
        return view.isDescendant(of: pdfView)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pageTap,
              let tap = otherGestureRecognizer as? UITapGestureRecognizer else { return false }
        return tap.numberOfTapsRequired > 1
    }

    @objc private func linkTapped() {
        guard let pdfView = pdfView, let target = target(linkTap.location(in: pdfView)) else { return }
        action(target)
    }

    @objc private func pageTapped() {
        guard let pdfView = pdfView, let document = pdfView.document,
              let page = pdfView.page(for: pageTap.location(in: pdfView), nearest: false) else { return }
        let index = document.index(for: page)
        if index != NSNotFound { onPageTap(index + 1) }
    }
}
