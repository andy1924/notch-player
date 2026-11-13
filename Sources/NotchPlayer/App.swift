import AppKit
import ApplicationServices
import OSLog
import SwiftUI

@main
struct NotchPlayerApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class NotchPanel: PlayerPanel {
    var handleCompactClick: (() -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        // Open on mouse down so a hover resize cannot cancel SwiftUI’s mouse-up action.
        if event.type == .leftMouseDown, handleCompactClick?() == true { return }
        super.sendEvent(event)
    }
}

private final class HoverView: NSHostingView<NotchView> {
    var hoverChanged: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeAlways, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverChanged?(true) }
    override func mouseExited(with event: NSEvent) {
        // Resizing the panel also rebuilds its tracking area.
        guard window?.frame.contains(NSEvent.mouseLocation) != true else { return }
        hoverChanged?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class LockHostingView: NSHostingView<LockCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    private let playback = Playback(preview: CommandLine.arguments.contains("--demo"))
    private lazy var listeningRecorder = ListeningRecorder()
    private var systemAwake = true
    private let notch = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
    private var lockCard: PlayerPanel?
    private var previewCard: PlayerPanel?
    private let lockArtwork = LockArtwork()
    private let previewArtwork = LockArtwork()
    private var desktopPanel: PlayerPanel?
    private var desktopCenter: CGPoint?
    private var isDraggingArtwork = false
    private var desktopStyle = DesktopStyle(rawValue: UserDefaults.standard.string(forKey: "desktopStyle") ?? "") ?? .turntable
    private lazy var lockSpace = LockScreenSpace()
    private var statusItem: NSStatusItem?
    private var hoverView: HoverView?
    private var expanded = false
    private let notchHover = NotchHover()
    private var isLocked = false
    private var screenAwake = true
    private var sessionActive = true
    private var lockPreview = false
    private var lockEnabled = UserDefaults.standard.object(forKey: "lockEnabled") as? Bool ?? true
    private var lockPoll: Timer?
    private var lockPresentationTask: Task<Void, Never>?
    private var lockStartedAt: ContinuousClock.Instant?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private lazy var cameraConnector = makeCameraConnector()
    private let menuMeasurements = DispatchQueue(label: "local.notchplayer.menu-geometry", qos: .utility)
    private var menuClearance: MenuBarClearance?
    private var recentMenuClearances: [pid_t: (clearance: MenuBarClearance, sampledAt: ContinuousClock.Instant)] = [:]
    private var measuredApp: pid_t?
    private var menuMeasurementInFlight = false
    private var menuMeasurementGeneration = 0
    private var menuAccess: Bool?
    private let menuLogger = Logger(subsystem: "local.notchplayer.app", category: "menu-clearance")
    private var menuPoll: Timer?
    private var tuckTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(notch, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        notch.handleCompactClick = { [weak self] in
            guard let self, !self.expanded, self.menuClearance?.compact != false else { return false }
            self.openNotchFromClick()
            return true
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Notch Player")
        buildMenu()

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(didLock), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(didUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(frontAppChanged),
                              name: NSWorkspace.didActivateApplicationNotification, object: nil)
        menuPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuClearance() }
        }
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidResign), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidActivate), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let outsideClickEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: outsideClickEvents) { [weak self] _ in
            let point = NSEvent.mouseLocation
            Task { @MainActor in self?.dismissNotchIfOutside(point) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: outsideClickEvents) { [weak self] event in
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            Task { @MainActor in self?.dismissNotchIfOutside(point) }
            return event
        }
        lockPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLockPresentation() }
        }
        playback.didSampleListening = { [weak self] source, date, tick in
            guard let self, self.systemAwake else { return }
            self.listeningRecorder.sample(source, at: date, tick: tick)
        }
        playback.didLoseListeningSample = { [weak self] in self?.listeningRecorder.interrupt() }
        playback.didUpdate = { [weak self] in
            self?.updateLockCard()
            self?.updateDesktop()
        }
        reconcileLock()
        refreshMenuClearance()
        renderNotch()
        playback.start()
    }

    private func makeLockCard(preview: Bool) -> PlayerPanel {
        let panel = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        let shielding = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        configure(panel, level: preview ? .floating : shielding)
        panel.canBecomeVisibleWithoutLogin = !preview
        panel.isReleasedWhenClosed = false
        return panel
    }

    private func makeCameraConnector() -> PlayerPanel {
        let panel = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        configure(panel, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        panel.backgroundColor = .black
        panel.ignoresMouseEvents = true
        return panel
    }

    private func dismissNotchIfOutside(_ point: CGPoint) {
        guard expanded, !notch.frame.contains(point) else { return }
        closeNotch()
    }

    private func configure(_ panel: NSPanel, level: NSWindow.Level) {
        panel.isOpaque = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    private var preferredScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func cameraGeometry(for screen: NSScreen) -> (center: CGFloat, width: CGFloat) {
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              left.width > 0, right.width > 0 else { return (screen.frame.midX, 180) }
        let width = screen.frame.width - left.width - right.width
        return (screen.frame.minX + left.width + width / 2, width)
    }

    @objc private func frontAppChanged() {
        refreshMenuClearance(force: true)
    }

    private func refreshMenuClearance(force: Bool = false) {
        let access = AXIsProcessTrusted()
        if access != menuAccess {
            menuAccess = access
            menuLogger.notice("Accessibility available: \(access)")
            buildMenu()
        }
        guard access, !isLocked, sessionActive, screenAwake,
              let screen = preferredScreen, screen.safeAreaInsets.top > 0,
              let frontApp = NSWorkspace.shared.frontmostApplication else {
            measuredApp = nil
            recentMenuClearances.removeAll()
            menuMeasurementGeneration += 1
            menuMeasurementInFlight = false
            applyMenuClearance(nil)
            return
        }

        let pid = frontApp.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        if menuMeasurementInFlight, !force, measuredApp == pid { return }
        let appChanged = measuredApp != pid
        measuredApp = pid
        menuMeasurementGeneration += 1
        let generation = menuMeasurementGeneration
        menuMeasurementInFlight = true
        let camera = cameraGeometry(for: screen)
        let mainTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let menuTop = mainTop - screen.frame.maxY
        let menuHeight = screen.safeAreaInsets.top
        let available = screen.frame.width - 24
        let compactWidth = min(camera.width + 80, available)
        let expandedWidth = min(390, available)
        let compact = CGRect(x: camera.center - compactWidth / 2, y: menuTop,
                             width: compactWidth, height: menuHeight)
        let expanded = CGRect(x: camera.center - expandedWidth / 2, y: menuTop,
                              width: expandedWidth, height: menuHeight)

        menuMeasurements.async { [weak self] in
            let clearance = MenuBarClearance.measure(pid: pid, compact: compact, expanded: expanded)
            Task { @MainActor in
                guard let self, self.menuMeasurementGeneration == generation else { return }
                self.menuMeasurementInFlight = false
                let now = ContinuousClock.now
                self.recentMenuClearances = self.recentMenuClearances.filter {
                    $0.value.sampledAt.duration(to: now) < .seconds(12)
                }
                if let clearance { self.recentMenuClearances[pid] = (clearance, now) }
                let resolved = clearance ?? self.recentMenuClearances[pid]?.clearance
                if appChanged || self.menuClearance != resolved {
                    let outcome = resolved.map { $0.compact ? "clear" : "crowded" } ?? "geometry unavailable"
                    self.menuLogger.notice("Menu measurement for pid \(pid): \(outcome, privacy: .public)")
                }
                self.applyMenuClearance(resolved)
            }
        }
    }

    private func applyMenuClearance(_ clearance: MenuBarClearance?) {
        guard menuClearance != clearance else { return }
        let wasCrowded = menuClearance?.compact == false
        menuClearance = clearance

        if clearance?.compact == false {
            if !wasCrowded { tuckNotch() }
            return
        }

        tuckTask?.cancel()
        tuckTask = nil
        let canAnimate = wasCrowded && !isLocked && sessionActive && screenAwake
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if canAnimate, let screen = preferredScreen, screen.safeAreaInsets.top > 0, hoverView != nil {
            notch.setFrame(tuckedFrame(on: screen), display: true)
            if !notch.isVisible { notch.orderFrontRegardless() }
        }
        renderNotch(animationDuration: canAnimate ? 0.21 : 0)
    }

    private func tuckedFrame(on screen: NSScreen) -> CGRect {
        let camera = cameraGeometry(for: screen)
        let height = screen.safeAreaInsets.top
        let width = max(1, camera.width - 4)
        return CGRect(x: camera.center - width / 2, y: screen.frame.maxY - height,
                      width: width, height: height)
    }

    private func tuckNotch() {
        cameraConnector.orderOut(nil)
        expanded = false
        notchHover.isHighlighted = false
        guard notch.isVisible, let screen = preferredScreen, screen.safeAreaInsets.top > 0,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            notch.orderOut(nil)
            return
        }

        let frame = tuckedFrame(on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            notch.animator().setFrame(frame, display: true)
        }
        tuckTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self else { return }
            self.tuckTask = nil
            if self.menuClearance?.compact == false { self.notch.orderOut(nil) }
        }
    }

    @objc private func enableAdaptiveMenuDetection() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            refreshMenuClearance(force: true)
        }
    }

    private func renderNotch(animationDuration: TimeInterval = 0) {
        guard !isLocked, sessionActive, screenAwake, let screen = preferredScreen else {
            notchHover.isHighlighted = false
            cameraConnector.orderOut(nil)
            notch.orderOut(nil)
            return
        }

        let floating = screen.safeAreaInsets.top == 0
        if !floating, menuClearance?.compact == false {
            cameraConnector.orderOut(nil)
            if tuckTask == nil { notch.orderOut(nil) }
            return
        }
        // Separate the non-interactive camera area from the wide player when menus need the wings.
        let protectsMenus = !floating && expanded && menuClearance?.expanded == false
        let level = protectsMenus
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) - 1)
            : NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        if notch.level != level { notch.level = level }
        let topHeight = protectsMenus ? 0 : (floating ? 32 : screen.safeAreaInsets.top)
        let camera = cameraGeometry(for: screen)
        let compactWidth = floating ? 132 : camera.width + 64
        let hovered = !expanded && notchHover.isHighlighted
        let width = min(expanded ? 390 : compactWidth + (hovered ? 16 : 0), screen.frame.width - 24)
        let height = topHeight + (expanded ? 140 : (hovered ? 5 : 0))
        let top = floating ? screen.visibleFrame.maxY - 5
            : screen.frame.maxY - (protectsMenus ? screen.safeAreaInsets.top : 0)
        if protectsMenus {
            let connectorFrame = tuckedFrame(on: screen)
            if cameraConnector.frame != connectorFrame { cameraConnector.setFrame(connectorFrame, display: true) }
            if !cameraConnector.isVisible { cameraConnector.orderFrontRegardless() }
        } else {
            cameraConnector.orderOut(nil)
        }
        let center = camera.center
        let frame = CGRect(x: center - width / 2, y: top - height, width: width, height: height)
        let view = NotchView(playback: playback, topHeight: hovered ? height : topHeight, floating: floating,
                             expanded: expanded, hover: notchHover, open: { [weak self] in self?.openNotchFromClick() },
                             dragArtwork: { [weak self] point, ended in self?.dragArtwork(to: point, ended: ended) })
        if let hoverView {
            hoverView.rootView = view
        } else {
            let hosting = HoverView(rootView: view)
            hosting.sizingOptions = []
            hosting.hoverChanged = { [weak self] inside in self?.setNotchHovered(inside) }
            notch.contentView = hosting
            hoverView = hosting
        }
        if animationDuration > 0, notch.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                notch.animator().setFrame(frame, display: true)
            }
        } else {
            notch.setFrame(frame, display: true)
        }
        if !notch.isVisible { notch.orderFrontRegardless() }
    }

    private func setNotchHovered(_ hovered: Bool) {
        guard menuClearance?.compact != false, notchHover.isHighlighted != hovered else { return }
        notchHover.isHighlighted = hovered
        if !expanded { renderNotch(animationDuration: 0.16) }
    }

    private func openNotchFromClick() {
        guard !expanded, menuClearance?.compact != false else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        showNotch()
    }

    private func closeNotch(animated: Bool = true) {
        notchHover.isHighlighted = false
        expanded = false
        renderNotch(animationDuration: animated ? 0.26 : 0)
    }

    private func dragArtwork(to point: CGPoint, ended: Bool) {
        let onDesktop = !notch.frame.contains(point)
        if ended {
            isDraggingArtwork = false
            if onDesktop {
                desktopCenter = point
                closeNotch()
            }
            updateDesktop()
            buildMenu()
        } else if onDesktop {
            isDraggingArtwork = true
            updateDesktop(at: point)
        } else if isDraggingArtwork {
            isDraggingArtwork = false
            updateDesktop()
        }
    }

    private func updateDesktop(at dragPoint: CGPoint? = nil) {
        if isDraggingArtwork, dragPoint == nil { return }
        guard screenAwake, sessionActive, !isLocked, playback.track != nil,
              let point = dragPoint ?? desktopCenter,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? preferredScreen else {
            desktopPanel?.orderOut(nil)
            return
        }

        let panel: PlayerPanel
        if let existing = desktopPanel {
            panel = existing
        } else {
            panel = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            configure(panel, level: .normal)
            panel.ignoresMouseEvents = true
            let hosting = NSHostingView(rootView: DesktopPlayer(playback: playback, style: desktopStyle))
            hosting.sizingOptions = []
            panel.contentView = hosting
            desktopPanel = panel
        }

        let width = min(460, screen.visibleFrame.width - 24)
        let height = width * 315 / 460
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let x = min(max(point.x - width / 2, visible.minX), visible.maxX - width)
        let y = min(max(point.y - height / 2, visible.minY), visible.maxY - height)
        let frame = CGRect(x: x, y: y, width: width, height: height)
        let level = dragPoint == nil
            ? NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            : .floating
        if panel.level != level { panel.level = level }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func setDesktopStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = DesktopStyle(rawValue: raw) else { return }
        desktopStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "desktopStyle")
        if let hosting = desktopPanel?.contentView as? NSHostingView<DesktopPlayer> {
            hosting.rootView = DesktopPlayer(playback: playback, style: style)
        }
        if desktopCenter == nil, let screen = preferredScreen {
            desktopCenter = CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY)
        }
        updateDesktop()
        buildMenu()
    }

    @objc private func hideDesktopPlayer() {
        desktopCenter = nil
        updateDesktop()
        buildMenu()
    }

    private func updateLockCard(reassert: Bool = false) {
        let preview = lockPreview && !isLocked
        if !preview { previewCard?.orderOut(nil) }
        let shouldShowOnLock = isLocked && lockEnabled && playback.track != nil
            && (sessionActive || sessionOnConsole)
        guard screenAwake, let screen = NSScreen.screens.first,
              (preview && sessionActive) || shouldShowOnLock else {
            if let lockCard, lockCard.isVisible {
                lockCard.orderOut(nil)
                lockSpace?.hide()
            }
            previewCard?.orderOut(nil)
            return
        }

        let existing = preview ? previewCard : lockCard
        let panel = existing ?? makeLockCard(preview: preview)
        if preview {
            previewCard = panel
        } else {
            lockCard = panel
        }

        let artwork = preview ? previewArtwork : lockArtwork
        let width = min(artwork.mode == .lyrics ? 632 : 376, screen.frame.width - 32)
        let artSize: CGFloat = screen.frame.height >= 820 ? 176 : 122
        let height = artSize + (preview ? 156 : 136)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2,
                           width: width, height: height)
        if panel.contentView == nil || panel.frame.height != frame.height {
            let hosting = LockHostingView(rootView: LockCard(playback: playback, preview: preview,
                                                             artSize: artSize, artwork: artwork,
                                                             modeChanged: { [weak self] in self?.updateLockCard() }))
            hosting.sizingOptions = []
            panel.contentView = hosting
        }
        if frame != panel.frame { panel.setFrame(frame, display: true) }
        if reassert || !panel.isVisible {
            if !preview { lockSpace?.show(panel) }
            panel.orderFrontRegardless()
        }
    }

    private var sessionOnConsole: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["kCGSSessionOnConsoleKey"] as? Bool == true
    }

    private func reconcileLock() {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return }
        let locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        // The distributed lock notification can arrive before the session dictionary changes.
        if !locked, let lockStartedAt, lockStartedAt.duration(to: .now) < .seconds(2) { return }
        setLocked(locked)
    }

    private func checkLockPresentation() {
        reconcileLock()
        if isLocked { updateLockCard(reassert: true) }
    }

    private func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        lockStartedAt = locked ? .now : nil
        if locked {
            lockPreview = false
            previewArtwork.mode = .record
            closeNotch(animated: false)
            playback.refresh()
        } else {
            lockArtwork.mode = .record
            renderNotch()
        }
        isDraggingArtwork = false
        if !locked { refreshMenuClearance(force: true) }
        buildMenu()
        updateLockCard()
        updateDesktop()
        refreshLockPresentation()
    }

    private func refreshLockPresentation() {
        lockPresentationTask?.cancel()
        guard isLocked, screenAwake else { return }
        // WindowServer may rebuild the set of visible spaces after lock and display wake.
        lockPresentationTask = Task { [weak self] in
            for delay in [120, 300, 650, 1000] {
                do { try await Task.sleep(for: .milliseconds(delay)) } catch { return }
                guard let self, self.isLocked, self.screenAwake else { return }
                self.updateLockCard(reassert: true)
            }
        }
    }

    @objc private func didLock() { setLocked(true) }
    @objc private func didUnlock() { setLocked(false) }
    @objc private func screenChanged() {
        if !screenAwake || !sessionActive { isDraggingArtwork = false }
        refreshMenuClearance(force: true)
        renderNotch()
        updateLockCard()
        updateDesktop()
        refreshLockPresentation()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if !playback.preview { listeningRecorder.interrupt() }
    }

    @objc private func systemWillSleep() {
        systemAwake = false
        if !playback.preview { listeningRecorder.interrupt() }
    }

    @objc private func systemDidWake() {
        systemAwake = true
        playback.refresh()
    }

    @objc private func screenDidSleep() {
        screenAwake = false
        screenChanged()
    }

    @objc private func screenDidWake() {
        screenAwake = true
        reconcileLock()
        screenChanged()
    }

    @objc private func sessionDidResign() {
        sessionActive = false
        reconcileLock()
        screenChanged()
    }

    @objc private func sessionDidActivate() {
        sessionActive = true
        reconcileLock()
        screenChanged()
    }

    @objc private func toggleLockPreview() {
        lockPreview.toggle()
        if !lockPreview { previewArtwork.mode = .record }
        buildMenu()
        updateLockCard()
    }

    @objc private func toggleLockEnabled() {
        lockEnabled.toggle()
        UserDefaults.standard.set(lockEnabled, forKey: "lockEnabled")
        buildMenu()
        updateLockCard()
    }

    @objc private func showNotch() {
        guard !expanded, menuClearance?.compact != false else { return }
        expanded = true
        renderNotch(animationDuration: 0.26)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Notch Player", action: #selector(showNotch), keyEquivalent: "")
        menu.addItem(withTitle: lockPreview ? "Close Lock Screen Preview" : "Preview Lock Screen",
                     action: #selector(toggleLockPreview), keyEquivalent: "")
        let lock = menu.addItem(withTitle: "Show on Lock Screen", action: #selector(toggleLockEnabled),
                                keyEquivalent: "")
        lock.state = lockEnabled ? .on : .off
        if menuAccess != true, preferredScreen?.safeAreaInsets.top ?? 0 > 0 {
            menu.addItem(withTitle: "Enable Adaptive Menu Detection…",
                         action: #selector(enableAdaptiveMenuDetection), keyEquivalent: "")
        }
        menu.items.forEach { $0.target = self }
        let desktop = menu.addItem(withTitle: "Desktop Player", action: nil, keyEquivalent: "")
        let styles = NSMenu()
        for style in DesktopStyle.allCases {
            let item = styles.addItem(withTitle: style.title, action: #selector(setDesktopStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = desktopCenter != nil && desktopStyle == style ? .on : .off
        }
        if desktopCenter != nil {
            styles.addItem(.separator())
            let hide = styles.addItem(withTitle: "Hide Desktop Player", action: #selector(hideDesktopPlayer),
                                      keyEquivalent: "")
            hide.target = self
        }
        desktop.submenu = styles
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Notch Player", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        statusItem?.menu = menu
    }
}
