//
//  EPUBNavigatorViewController.swift
//  r2-navigator-swift
//
//  Created by Winnie Quinn, Alexandre Camilleri on 8/23/17.
//
//  Copyright 2018 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import UIKit
import R2Shared
import WebKit
import SafariServices
import CommonCrypto

public protocol EPUBNavigatorDelegate: VisualNavigatorDelegate, SelectableNavigatorDelegate {
    
    // MARK: - Deprecated
    
    // Implement `NavigatorDelegate.navigator(didTapAt:)` instead.
    func middleTapHandler()

    // Implement `NavigatorDelegate.navigator(locationDidChange:)` instead, to save the last read location.
    func willExitPublication(documentIndex: Int, progression: Double?)
    func didChangedDocumentPage(currentDocumentIndex: Int)
    func didNavigateViaInternalLinkTap(to documentIndex: Int)

    /// Implement `NavigatorDelegate.navigator(presentError:)` instead.
    func presentError(_ error: NavigatorError)

}

public extension EPUBNavigatorDelegate {
    
    func middleTapHandler() {}
    func willExitPublication(documentIndex: Int, progression: Double?) {}
    func didChangedDocumentPage(currentDocumentIndex: Int) {}
    func didNavigateViaInternalLinkTap(to documentIndex: Int) {}
    func presentError(_ error: NavigatorError) {}

}


public typealias EPUBContentInsets = (top: CGFloat, bottom: CGFloat)

open class EPUBNavigatorViewController: UIViewController, VisualNavigator, Loggable {
    
    public struct Configuration {
        /// Authorized actions to be displayed in the selection menu.
        public var editingActions: [EditingAction] = EditingAction.defaultActions
        
        /// Content insets used to add some vertical margins around reflowable EPUB publications. The insets can be configured for each size class to allow smaller margins on compact screens.
        public var contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets] = [
            .compact: (top: 20, bottom: 20),
            .regular: (top: 44, bottom: 44)
        ]
        
        /// Number of positions (as in `Publication.positionList`) to preload before the current page.
        public var preloadPreviousPositionCount = 2
        
        /// Number of positions (as in `Publication.positionList`) to preload after the current page.
        public var preloadNextPositionCount = 6
        
        public init() {}
    }
    
    public weak var delegate: EPUBNavigatorDelegate? {
        didSet { notifyCurrentLocation() }
    }
    public var userSettings: UserSettings
    
    private let config: Configuration
    private let publication: Publication
    private let license: DRMLicense?
    private let editingActions: EditingActionsController

    public var readingProgression: ReadingProgression {
        didSet { reloadSpreads() }
    }

    /// Base URL on the resources server to the files in Static/
    /// Used to serve the ReadiumCSS files.
    private let resourcesURL: URL?

    public init(publication: Publication, license: DRMLicense? = nil, initialLocation: Locator? = nil, resourcesServer: ResourcesServer, config: Configuration = .init()) {
        self.publication = publication
        self.license = license
        self.editingActions = EditingActionsController(actions: config.editingActions, license: license)
        self.userSettings = UserSettings()
        publication.userProperties.properties = self.userSettings.userProperties.properties
        self.readingProgression = publication.contentLayout.readingProgression
        self.config = config
        self.paginationView = PaginationView(frame: .zero, preloadPreviousPositionCount: config.preloadPreviousPositionCount, preloadNextPositionCount: config.preloadNextPositionCount)

        self.resourcesURL = {
            do {
                guard let baseURL = Bundle(for: EPUBNavigatorViewController.self).resourceURL else {
                    return nil
                }
                return try resourcesServer.serve(
                   baseURL.appendingPathComponent("Static"),
                    at: "/r2-navigator/epub"
                )
            } catch {
                EPUBNavigatorViewController.log(.error, error)
                return nil
            }
        }()

        super.init(nibName: nil, bundle: nil)
        
        self.editingActions.delegate = self
        self.paginationView.delegate = self
        reloadSpreads(at: initialLocation)
    }

    @available(*, unavailable)
    public required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        paginationView.backgroundColor = .clear
        paginationView.frame = view.bounds
        paginationView.autoresizingMask = [.flexibleHeight, .flexibleWidth]
        view.addSubview(paginationView)
        let notification = Notification.Name(rawValue: "pageLoaded")
        NotificationCenter.default.post(name: notification, object: self, userInfo:nil)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        // FIXME: Deprecated, to be removed at some point.
        if let currentResourceIndex = currentResourceIndex {
            let progression = currentLocation?.locations.progression
            delegate?.willExitPublication(documentIndex: currentResourceIndex, progression: progression)
        }
    }
    
    open override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate(alongsideTransition: { [weak self] context in
            self?.reloadSpreads()
        })
    }

    /// Mapping between reading order hrefs and the table of contents title.
    private lazy var tableOfContentsTitleByHref: [String: String] = {
        func fulfill(linkList: [Link]) -> [String: String] {
            var result = [String: String]()
            
            for link in linkList {
                if let title = link.title {
                    result[link.href] = title
                }
                let subResult = fulfill(linkList: link.children)
                result.merge(subResult) { (current, another) -> String in
                    return current
                }
            }
            return result
        }
        
        return fulfill(linkList: publication.tableOfContents)
    }()

    /// Goes to the reading order resource at given `index`, and given content location.
    @discardableResult
    private func goToReadingOrderIndex(_ index: Int, location: Locator? = nil, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        let href = publication.readingOrder[index].href
        guard let spreadIndex = spreads.firstIndex(withHref: href) else {
            return false
        }
        return paginationView.goToIndex(spreadIndex, location: location, animated: animated, completion: completion)
    }
    
    /// Goes to the next or previous page in the given scroll direction.
    private func go(to direction: EPUBSpreadView.Direction, animated: Bool, completion: @escaping () -> Void) -> Bool {
        if let spreadView = paginationView.currentView as? EPUBSpreadView,
            spreadView.go(to: direction, animated: animated, completion: completion)
        {
            return true
        }
        
        let delta = readingProgression == .rtl ? -1 : 1
        switch direction {
        case .left:
            return paginationView.goToIndex(currentSpreadIndex - delta, animated: animated, completion: completion)
        case .right:
            return paginationView.goToIndex(currentSpreadIndex + delta, animated: animated, completion: completion)
        }
    }
    
    
    // MARK: - User settings
    
    public func updateUserSettingStyle() {
        assert(Thread.isMainThread, "User settings must be updated from the main thread")
        
        guard !paginationView.isEmpty else {
            return
        }
        
        reloadSpreads()
        
        let location = currentLocation
        for (_, view) in paginationView.loadedViews {
            (view as? EPUBSpreadView)?.applyUserSettingsStyle()
        }
        
        // Re-positions the navigator to the location before applying the settings
        if let location = location {
            go(to: location)
        }
    }

    
    // MARK: - Pagination and spreads
    
    private let paginationView: PaginationView
    private var spreads: [EPUBSpread] = []

    /// Index of the currently visible spread.
    private var currentSpreadIndex: Int {
        return paginationView.currentIndex
    }

    // Reading order index of the left-most resource in the visible spread.
    private var currentResourceIndex: Int? {
        return publication.readingOrder.firstIndex(withHref: spreads[currentSpreadIndex].left.href)
    }

    private func reloadSpreads(at location: Locator? = nil) {
        let isLandscape = (view.bounds.width > view.bounds.height)
        let pageCountPerSpread = EPUBSpread.pageCountPerSpread(for: publication, userSettings: userSettings, isLandscape: isLandscape)
        guard spreads.first?.pageCount != pageCountPerSpread else {
            // Already loaded with the expected amount of spreads.
            return
        }

        let location = location ?? currentLocation
        spreads = EPUBSpread.makeSpreads(for: publication, readingProgression: readingProgression, pageCountPerSpread: pageCountPerSpread)
        
        let initialIndex: Int = {
            if let href = location?.href, let foundIndex = spreads.firstIndex(withHref: href) {
                return foundIndex
            } else {
                return 0
            }
        }()
        
        paginationView.reloadAtIndex(initialIndex, location: location, pageCount: spreads.count, readingProgression: readingProgression)
    }

    
    // MARK: - Navigator
    
    public var currentLocation: Locator? {
        guard let spreadView = paginationView.currentView as? EPUBSpreadView,
            let href = Optional(spreadView.spread.leading.href),
            let positionList = publication.positionListByResource[href],
            positionList.count > 0 else
        {
            return nil
        }

        // Gets the current locator from the positionList, and fill its missing data.
        let progression = spreadView.progression(in: href)
        let positionIndex = Int(ceil(progression * Double(positionList.count - 1)))
        var locator = positionList[positionIndex]
        locator.title = tableOfContentsTitleByHref[href]
        locator.locations.progression = progression
        return locator
    }

    /// Last current location notified to the delegate.
    /// Used to avoid sending twice the same location.
    private var notifiedCurrentLocation: Locator?
    
    fileprivate func notifyCurrentLocation() {
        guard let delegate = delegate,
            let location = currentLocation,
            location != notifiedCurrentLocation else
        {
            return
        }
        notifiedCurrentLocation = location
        delegate.navigator(self, locationDidChange: location)
    }
    
    public func go(to locator: Locator, animated: Bool, completion: @escaping () -> Void) -> Bool {
        guard let spreadIndex = spreads.firstIndex(withHref: locator.href) else {
            return false
        }
        return paginationView.goToIndex(spreadIndex, location: locator, animated: animated, completion: completion)
    }
    
    public func go(to link: Link, animated: Bool, completion: @escaping () -> Void) -> Bool {
        return go(to: Locator(link: link), animated: animated, completion: completion)
    }
    
    public func goForward(animated: Bool, completion: @escaping () -> Void) -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch readingProgression {
            case .ltr, .auto:
                return .right
            case .rtl:
                return .left
            }
        }()
        return go(to: direction, animated: animated, completion: completion)
    }
    
    public func goBackward(animated: Bool, completion: @escaping () -> Void) -> Bool {
        let direction: EPUBSpreadView.Direction = {
            switch readingProgression {
            case .ltr, .auto:
                return .left
            case .rtl:
                return .right
            }
        }()
        return go(to: direction, animated: animated, completion: completion)
    }
    
}

extension EPUBNavigatorViewController: EPUBSpreadViewDelegate {
    
    func spreadViewWillAnimate(_ spreadView: EPUBSpreadView) {
        paginationView.isUserInteractionEnabled = false
    }
    
    func spreadViewDidAnimate(_ spreadView: EPUBSpreadView) {
        paginationView.isUserInteractionEnabled = true
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, didTapAt point: CGPoint) {
        let point = view.convert(point, from: spreadView)
        delegate?.navigator(self, didTapAt: point)
        // FIXME: Deprecated, to be removed at some point.
        delegate?.middleTapHandler()
        
        // Uncomment to debug the coordinates of the tap point.
//        let tapView = UIView(frame: .init(x: 0, y: 0, width: 50, height: 50))
//        view.addSubview(tapView)
//        tapView.backgroundColor = .red
//        tapView.center = point
//        tapView.layer.cornerRadius = 25
//        tapView.layer.masksToBounds = true
//        UIView.animate(withDuration: 0.8, animations: {
//            tapView.alpha = 0
//        }) { _ in
//            tapView.removeFromSuperview()
//        }
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL) {
        delegate?.navigator(self, presentExternalURL: url)
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String) {
        go(to: Link(href: href))
    }
    
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView) {
        if paginationView.currentView == spreadView {
            notifyCurrentLocation()
        }
    }
    
    func spreadView(_ spreadView: EPUBSpreadView, present viewController: UIViewController) {
        present(viewController, animated: true)
    }

    func spreadView(_ spreadView: EPUBSpreadView, selectionDidChange selection: (text: String, frame: CGRect)) {
        self.delegate?.navigator(self, didChangeSelection: selection)
    }
}

extension EPUBNavigatorViewController: EditingActionsControllerDelegate {
    
    func editingActionsDidPreventCopy(_ editingActions: EditingActionsController) {
        delegate?.navigator(self, presentError: .copyForbidden)
        // FIXME: Deprecated, to be removed at some point.
        delegate?.presentError(.copyForbidden)
    }
    
}

extension EPUBNavigatorViewController: PaginationViewDelegate {
    
    func paginationView(_ paginationView: PaginationView, pageViewAtIndex index: Int, location: Locator) -> (UIView & PageView)? {
        let spread = spreads[index]
        let spreadViewType = (spread.layout == .fixed) ? EPUBFixedSpreadView.self : EPUBReflowableSpreadView.self
        let spreadView = spreadViewType.init(
            publication: publication,
            spread: spread,
            resourcesURL: resourcesURL,
            initialLocation: location,
            contentLayout: publication.contentLayout,
            readingProgression: readingProgression,
            userSettings: userSettings,
            animatedLoad: false,  // FIXME: custom animated
            editingActions: editingActions,
            contentInset: config.contentInset
        )
        spreadView.delegate = self
        return spreadView
    }
    
    func paginationViewDidUpdateViews(_ paginationView: PaginationView) {
        // notice that you should set the delegate before you load views
        // otherwise, when open the publication, you may miss the first invocation
        notifyCurrentLocation()

        // FIXME: Deprecated, to be removed at some point.
        if let currentResourceIndex = currentResourceIndex {
            delegate?.didChangedDocumentPage(currentDocumentIndex: currentResourceIndex)
        }
    }
    
}


// MARK: - Deprecated

@available(*, deprecated, renamed: "EPUBNavigatorViewController")
public typealias NavigatorViewController = EPUBNavigatorViewController

@available(*, deprecated, message: "Use the `animated` parameter of `goTo` functions instead")
public enum PageTransition {
    case none
    case animated
}

extension EPUBNavigatorViewController {
    
    /// This initializer is deprecated.
    /// Replace `pageTransition` by the `animated` property of the `goTo` functions.
    /// Replace `disableDragAndDrop` by `EditingAction.copy`, since drag and drop is equivalent to copy.
    /// Replace `initialIndex` and `initialProgression` by `initialLocation`.
    @available(*, deprecated, renamed: "init(publication:license:initialLocation:resourcesServer:config:)")
    public convenience init(for publication: Publication, license: DRMLicense? = nil, initialIndex: Int, initialProgression: Double?, pageTransition: PageTransition = .none, disableDragAndDrop: Bool = false, editingActions: [EditingAction] = EditingAction.defaultActions, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]? = nil) {
        fatalError("This initializer is not available anymore.")
    }
    
    /// This initializer is deprecated.
    /// Use the new Configuration object.
    @available(*, deprecated, renamed: "init(publication:license:initialLocation:resourcesServer:config:)")
    public convenience init(publication: Publication, license: DRMLicense? = nil, initialLocation: Locator? = nil, editingActions: [EditingAction] = EditingAction.defaultActions, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]? = nil, resourcesServer: ResourcesServer) {
        var config = Configuration()
        config.editingActions = editingActions
        if let contentInset = contentInset {
            config.contentInset = contentInset
        }
        self.init(publication: publication, license: license, initialLocation: initialLocation, resourcesServer: resourcesServer, config: config)
    }

    @available(*, deprecated, message: "Use the `animated` parameter of `goTo` functions instead")
    public var pageTransition: PageTransition {
        get { return .none }
        set {}
    }
    
    @available(*, deprecated, message: "Bookmark model is deprecated, use your own model and `currentLocation`")
    public var currentPosition: Bookmark? {
        guard let publicationID = publication.metadata.identifier,
            let locator = currentLocation,
            let currentResourceIndex = currentResourceIndex else
        {
            return nil
        }
        return Bookmark(
            publicationID: publicationID,
            resourceIndex: currentResourceIndex,
            locator: locator
        )
    }

    @available(*, deprecated, message: "Use `publication.readingOrder` instead")
    public func getReadingOrder() -> [Link] { return publication.readingOrder }
    
    @available(*, deprecated, message: "Use `publication.tableOfContents` instead")
    public func getTableOfContents() -> [Link] { return publication.tableOfContents }

    @available(*, deprecated, renamed: "go(to:)")
    public func displayReadingOrderItem(at index: Int) {
        goToReadingOrderIndex(index)
    }
    
    @available(*, deprecated, renamed: "go(to:)")
    public func displayReadingOrderItem(at index: Int, progression: Double) {
        var location = Locator(link: publication.readingOrder[index])
        location.locations = Locations(progression: progression)
        goToReadingOrderIndex(index, location: location)
    }
    
    @available(*, deprecated, renamed: "go(to:)")
    public func displayReadingOrderItem(with href: String) -> Int? {
        let index = publication.readingOrder.firstIndex(withHref: href)
        let moved = go(to: Link(href: href))
        return moved ? index : nil
    }
    
}

extension EPUBNavigatorViewController : HighlightableNavigator {
    
    public func rectangleForHighlightWithID(_ id: String, callback: @escaping (CGRect?) -> Void) {
        executeJavascript("rectangleForHighlightWithID(\'\(id)\')") {
            result, error in
            callback(
                CGRect(
                    x: result!["left"] as! Double,
                    y: result!["top"] as! Double,
                    width: result!["screenWidth"] as! Double,
                    height: result!["screenHeight"] as! Double
                )
            )
        }
    }
    
    public func rectangleForHighlightAnnotationMarkWithID(_ id: String) -> CGRect? {
        return nil
    }
    
    public func highlightActivated(_ id: String) {
        let notification = Notification.Name(rawValue: "highlightActivated")
        let userInfo = [
            "id": id
        ]
        NotificationCenter.default.post(name: notification, object: self, userInfo:userInfo)
    }
    
    public func highlightAnnotationMarkActivated(_ id: String) {
        
        let notification = Notification.Name(rawValue: "annotationActivated")
        let userInfo = [
            "id": id
        ]
        NotificationCenter.default.post(name: notification, object: self, userInfo:userInfo)
    }
    
    
    struct Holder {
        static var _lastHighlightInfo:NSDictionary = [:]
        static var _highlightList: Array<(String,String)> = Array()
    }
    var lastHighlightInfo:NSDictionary {
        get {
            return Holder._lastHighlightInfo
        }
        set(newValue) {
            Holder._lastHighlightInfo = newValue
        }
    }
    var highlightList: Array<(String,String)> {
        get {
            return Holder._highlightList
        }
        set(newValue) {
            Holder._highlightList = newValue
        }
    }
    
    
    public func frameForHighlightWithID(_ id: String, completionHandler: @escaping (String?, Error?) -> Void) {
        
        
        let highlightID = id
        executeJavascript("getHighlightFrame(\'\(highlightID)\')") { result, error in
            guard let position =  result else {
                return
            }
            
            
            let positionInfo = self.convJSON(position)
            completionHandler(positionInfo, error)
        }
    }
    
    
    private func executeJavascript(_ param: String, completionHandler: @escaping (NSDictionary?, Error?) -> Void) {
        guard let documentWebView = (paginationView.currentView as? EPUBSpreadView) else {
            return
        }
        
        documentWebView.evaluateScript(param, inResource: "") {
            result, error in
            guard let ret =  result as? NSDictionary else {
                print(error)
                return
            }
            completionHandler(ret, error)
        }
    }
    
    private func convJSON (_ dictionary: NSDictionary) -> String? {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: .prettyPrinted) {
            let theJSONText = String(data:jsonData,encoding:.ascii)!
            return theJSONText
        }
        return nil
    }
    
    public func showAnnotation(_ id: String) {
        executeJavascript("createAnnotation(\'\(id)\')") {
            _, _ in
        }
    }
    
    public func showHighlight(_ highlight: Highlight, completion: ((Highlight) -> Void)?) {
        
        let color = highlight.color ?? .green
        let components = self.rgbComponents(of: color)
        let colorDic:NSDictionary = [
            "red" : components.red,
            "green" : components.green,
            "blue"  : components.blue
        ]
        
        guard let colorInfo:String = convJSON(colorDic) else {
            return
        }
        
        executeJavascript("createHighlight(\(highlight.locator), \(colorInfo) ,true)") {
            result, error in
            guard let position = result else {
                print(error)
                return
            }
            
            if !highlight.style.isEmpty {
                self.showAnnotation(highlight.id)
            }
            
            if let requiredCompletion = completion {
                                
                requiredCompletion(
                    Highlight(id: position["id"] as? String ?? "",
                              locator: highlight.locator,
                              style: "")
                )
            }
        }
        return
    }
    
    public func showHighlights(_ highlights: [Highlight]) {
        return
    }
    
    public func hideHighlightWithID(_ id: String) {
        return
    }
    
    public func hideAllHighlights() {
        return
    }
    
    public func frameForHighlightWithID(_ id: String) -> CGRect? {
        return CGRect(x:0,y:0,width:0,height:0)
    }
    
    public func frameForHighlightAnnotationMarkWithID(_ id: String) -> CGRect? {
        return CGRect(x:0,y:0,width:0,height:0)
    }
    
    public func currentSelection(completion: @escaping (Locator?) -> Void) {
        executeJavascript("getCurrentSelectionInfo()") {
            result, error in
            guard let resultPos =  result?["locations"] as? NSDictionary else {
                print(error)
                return
            }
            let resource = self.publication.readingOrder[self.paginationView.currentIndex]
            let progression = self.currentLocation?.locations.progression
            let locator = Locator(
                href: resource.href,
                type: resource.type ?? "text/html",
                title: self.tableOfContentsTitleByHref[resource.href],
                locations: Locations(
                    progression:  progression ?? 0,
                    cssSelector: resultPos["cssSelector"] as? String,
                    partialCfi: resultPos["partialCfi"] as? String,
                    domRange: resultPos["domRange"] as? NSDictionary
                ),
                text: LocatorText(
                    highlight:  (result?["text"] as! NSDictionary)["highlight"] as! String
                )
            )
            completion(locator)
        }
    }
    
    public func deleteHighlight(_ id: String) {
        executeJavascript("destroyHighlight(\'\(id)\')") {
            result, error in
        }
        executeJavascript("destroyHighlight(\'\(id.replacingOccurrences(of: "HIGHLIGHT", with: "ANNOTATION"))\')") {
            result, error in
            
        }
    }
    
    @objc internal func convJSON (dictionary: NSDictionary) -> String? {
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: dictionary,
            options: .prettyPrinted) {
            let theJSONText = String(data:jsonData,encoding:.ascii)!
            return theJSONText
        }
        return nil
    }
    
    public func createHighlight(_ colorInfo:NSDictionary, completion: @escaping (Highlight) -> Void) {
        currentSelection { locator in
            let locations:NSDictionary = [
                "cssSelector" : locator?.locations.cssSelector ?? "",
                "partialCfi" : locator?.locations.partialCfi ?? "",
                "domRange"  : locator?.locations.domRange ?? ""
            ]
            let location:NSDictionary = [
                "locations" : locations
            ]
            
            self.executeJavascript("createHighlight(\(self.convJSON(location)!), \(self.convJSON(colorInfo)!) ,true)") {
                result, error in
                guard let resultPos =  result else {
                    return
                }
                
                completion(
                    Highlight(
                        id: resultPos["id"] as? String ?? "",
                        locator: locator!,
                        style: ""
                    )
                )
            }
        }
    }
}

// MARK: -
// MARK: Private
extension EPUBNavigatorViewController {
    
    func rgbComponents(of color: UIColor) -> (red: Int, green: Int, blue: Int) {
        var components: [CGFloat] {
            let comps = color.cgColor.components!
            if comps.count == 4 { return comps }
            return [comps[0], comps[0], comps[0], comps[1]]
        }
        let red = components[0]
        let green = components[1]
        let blue = components[2]
        return (red: Int(red * 255.0), green: Int(green * 255.0), blue: Int(blue * 255.0))
    }
}
