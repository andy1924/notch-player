import AppKit
import ApplicationServices

struct MenuBarClearance: Equatable {
    let compact: Bool
    let expandedWidth: CGFloat

    static func measure(pid: pid_t, compact: CGRect, expanded: CGRect) -> Self? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let menuBar = attribute(kAXMenuBarAttribute, of: app),
              CFGetTypeID(menuBar) == AXUIElementGetTypeID(),
              let items = attribute(kAXChildrenAttribute, of: (menuBar as! AXUIElement)) as? [AXUIElement],
              !items.isEmpty else { return nil }

        let frames = items.compactMap(frame)
        guard !frames.isEmpty else { return nil }
        return classify(menuItems: frames, compact: compact, expanded: expanded)
    }

    private static func frame(of item: AXUIElement) -> CGRect? {
        // Some menu item providers expose geometry only through individual requests.
        guard let position = attribute(kAXPositionAttribute, of: item),
              let dimensions = attribute(kAXSizeAttribute, of: item),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(dimensions) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(dimensions as! AXValue, .cgSize, &size),
              point.x.isFinite, point.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: point, size: size)
    }

    static func classify(menuItems: [CGRect], compact: CGRect, expanded: CGRect) -> Self {
        let compactZone = compact.insetBy(dx: -4, dy: 0)
        let center = expanded.midX
        let nearestMenu = menuItems
            .filter { $0.maxY > expanded.minY && $0.minY < expanded.maxY }
            .map { max(0, max(center - $0.maxX, $0.minX - center)) }
            .min() ?? expanded.width / 2
        let compactClear = !menuItems.contains { $0.intersects(compactZone) }
        return Self(compact: compactClear, expandedWidth: min(expanded.width, floor(nearestMenu * 2)))
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
