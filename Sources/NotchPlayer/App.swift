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
    private(set) var isHandlingPointerSequence = false
    private var consumesOpeningMouseUp = false
    var keyboardEnabled = false
    var toggleMusicPlayback: (() -> Bool)?
    override var canBecomeKey: Bool { keyboardEnabled }
    var handleCompactClick: (() -> Bool)?
    var handlePageSwipe: ((Bool) -> Bool)?
    private var scrollDistance: CGFloat = 0
    private var verticalDistance: CGFloat = 0
    private var didPage = false
    private var lastScrollTimestamp: TimeInterval = 0

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            isHandlingPointerSequence = true
            // Expansion creates new controls beneath the pointer. Its opening
            // gesture must finish before those controls can receive a click.
            if handleCompactClick?() == true {
                consumesOpeningMouseUp = true
                return
            }
        }
        if event.type == .leftMouseUp {
            defer { isHandlingPointerSequence = false }
            if consumesOpeningMouseUp {
                consumesOpeningMouseUp = false
                return
            }
            super.sendEvent(event)
            return
        }
        if event.type == .scrollWheel, trackPageSwipe(event) { return }
        if event.type == .keyDown, event.keyCode == 49,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.isARepeat { return }
            if toggleMusicPlayback?() == true { return }
        }
        super.sendEvent(event)
    }

    @discardableResult
    func trackPageSwipe(_ event: NSEvent) -> Bool {
        guard event.momentumPhase.isEmpty else { return false }
        let phased = !event.phase.isEmpty
        let began = !event.phase.intersection([.began, .mayBegin]).isEmpty
        if began || event.timestamp - lastScrollTimestamp > 0.22 {
            scrollDistance = 0
            verticalDistance = 0
            didPage = false
        }
        lastScrollTimestamp = event.timestamp
        if !event.phase.intersection([.cancelled, .ended]).isEmpty {
            scrollDistance = 0
            verticalDistance = 0
            didPage = false
            return false
        }
        guard !phased || !event.phase.intersection([.began, .changed]).isEmpty else { return false }
        if didPage { return true }

        // Global events can arrive while the nonactivating panel is above another app.
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        scrollDistance += event.scrollingDeltaX * direction * scale
        verticalDistance += abs(event.scrollingDeltaY) * scale
        if abs(scrollDistance) >= 10, abs(scrollDistance) > verticalDistance * 1.15 {
            didPage = handlePageSwipe?(scrollDistance < 0) == true
        }
        return didPage
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        // The glass background is visual-only. Blank space inside the player
        // still belongs to this window and must absorb the pointer event.
        return super.hitTest(point) ?? self
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

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
    private var fullNotch = false
    private var glassNotch = UserDefaults.standard.bool(forKey: "glassNotch")
    private var floatingNotch = UserDefaults.standard.bool(forKey: "floatingNotch")
    private let notchHover = NotchHover()
    private let notchPages = NotchPages()
    private var isLocked = false
    private var screenAwake = true
    private var sessionActive = true
    private var lockPreview = false
    private var lockEnabled = UserDefaults.standard.object(forKey: "lockEnabled") as? Bool ?? true
    private var lockPoll: Timer?
    private var lockPresentationTask: Task<Void, Never>?
    private var lockStartedAt: ContinuousClock.Instant?
    private var globalScrollMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
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
    private let clockReads = DispatchQueue(label: "local.notchplayer.clock-state", qos: .userInitiated)
    private var clockReadInFlight = false
    private var pendingStopwatch: (activity: ClockActivity?, expires: Date)?
    private var clockCommandInFlight = false
    private var clockActivities: [ClockActivity] = []
    private var clockPoll: Timer?
    private let clockCommands = DispatchQueue(label: "local.notchplayer.clock-controls", qos: .userInitiated)

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(notch, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))
        notch.handlePageSwipe = { [weak self] music in
            guard let self, !self.clockActivities.isEmpty, self.playback.track != nil else { return false }
            self.selectMusicPage(music)
            return true
        }
        notch.toggleMusicPlayback = { [weak self] in
            guard let self, self.expanded, self.notch.isVisible, !self.showingClockPage,
                  self.playback.track != nil else { return false }
            self.playback.send(.toggle)
            return true
        }
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
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let pointer = NSEvent.mouseLocation
            MainActor.assumeIsolated {
                guard let self, self.notch.isVisible, self.notch.frame.contains(pointer) else { return }
                self.notch.trackPageSwipe(event)
            }
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
            if let self, !self.clockActivities.isEmpty, self.notchPages.musicSelected,
               self.playback.track == nil {
                self.selectMusicPage(false)
            }
        }
        reconcileLock()
        refreshMenuClearance()
        renderNotch()
        playback.start()
        refreshClockActivities()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshClockActivities() }
        }
        timer.tolerance = 0.03
        RunLoop.main.add(timer, forMode: .common)
        clockPoll = timer
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

    private func dismissNotchIfOutside(_ point: CGPoint) {
        guard expanded, !notch.frame.contains(point) else { return }
        closeNotch()
    }

    private func configure(_ panel: NSPanel, level: NSWindow.Level) {
        panel.isOpaque = false
        panel.ignoresMouseEvents = false
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
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        if expanded, !notch.isKeyWindow, !notch.isHandlingPointerSequence,
           !notch.frame.contains(NSEvent.mouseLocation) {
            closeNotch()
        }
        refreshMenuClearance(force: true)
    }

    private func refreshMenuClearance(force: Bool = false) {
        let access = AXIsProcessTrusted()
        if access != menuAccess {
            menuAccess = access
            menuLogger.notice("Accessibility available: \(access)")
            buildMenu()
        }
        guard access, !floatingNotch, !isLocked, sessionActive, screenAwake,
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
        let compactWidth = min(camera.width + 90, available)
        let expandedWidth = min(475, available) - 2 * NotchShape.expandedShoulder
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
        expanded = false
        fullNotch = false
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

    private func refreshClockActivities() {
        guard systemAwake, screenAwake, sessionActive, !isLocked, !clockReadInFlight,
              !clockCommandInFlight else { return }
        clockReadInFlight = true
        clockReads.async { [weak self] in
            var reader = ClockActivityReader()
            let activities = reader.read()
            Task { @MainActor in
                guard let self else { return }
                self.clockReadInFlight = false
                guard !self.clockCommandInFlight else { return }
                var resolved = activities
                if let pending = self.pendingStopwatch {
                    let actual = activities.first { $0.kind == .stopwatch }
                    let matches = actual?.isPaused == pending.activity?.isPaused
                        && (actual == nil) == (pending.activity == nil)
                    if matches || pending.expires <= .now {
                        self.pendingStopwatch = nil
                    } else {
                        resolved.removeAll { $0.kind == .stopwatch }
                        if let activity = pending.activity { resolved.append(activity) }
                    }
                }
                self.applyClockActivities(resolved)
            }
        }
    }

    private func applyClockActivities(_ activities: [ClockActivity]) {
        guard clockActivities != activities else { return }
        if clockActivities.isEmpty || activities.isEmpty { notchPages.musicSelected = false }
        clockActivities = activities
        renderNotch()
    }

    private var showingClockPage: Bool {
        !clockActivities.isEmpty && (!notchPages.musicSelected || playback.track == nil)
    }

    private func selectMusicPage(_ music: Bool) {
        guard notchPages.musicSelected != music else { return }
        notchPages.musicSelected = music
        if !expanded { renderNotch(animationDuration: 0.19) }
    }

    private func sendStopwatchCommand(_ command: StopwatchCommand) {
        guard AXIsProcessTrusted() else {
            notchPages.clockMessage = "Allow Accessibility to control Clock"
            enableAdaptiveMenuDetection()
            return
        }
        guard let clock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.clock").first else {
            notchPages.clockMessage = "Open Stopwatch in Clock to use controls"
            return
        }
        guard !clockCommandInFlight else { return }
        clockCommandInFlight = true
        notchPages.clockMessage = nil
        let activity = clockActivities.first { $0.kind == .stopwatch }
        clockCommands.async { [weak self] in
            let pressed = Self.pressStopwatchButton(command, pid: clock.processIdentifier)
            Task { @MainActor in
                guard let self else { return }
                self.clockCommandInFlight = false
                self.notchPages.clockMessage = pressed ? nil : "Show the Stopwatch tab in Clock"
                if pressed, let activity, command != .lap {
                    let updated: ClockActivity?
                    switch command {
                    case .reset:
                        updated = nil
                    case .stop:
                        updated = ClockActivity(id: activity.id, kind: .stopwatch, title: activity.title,
                                                timing: .paused(activity.elapsedTime(at: .now)))
                    case .start:
                        updated = ClockActivity(id: activity.id, kind: .stopwatch, title: activity.title,
                                                timing: .countingUp(since: .now, offset: activity.elapsedTime(at: .now)))
                    case .lap:
                        updated = activity
                    }
                    self.pendingStopwatch = (updated, Date().addingTimeInterval(3))
                    var activities = self.clockActivities.filter { $0.kind != .stopwatch }
                    if let updated { activities.append(updated) }
                    self.applyClockActivities(activities)
                }
                self.refreshClockActivities()
            }
        }
    }

    private nonisolated static func pressStopwatchButton(_ command: StopwatchCommand, pid: pid_t) -> Bool {
        let clock = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(clock, 0.12)

        func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }

        for window in attribute(kAXWindowsAttribute, of: clock) as? [AXUIElement] ?? [] {
            var queue = [window]
            var index = 0
            var buttons: [String: AXUIElement] = [:]
            while index < queue.count, index < 160 {
                let element = queue[index]
                index += 1
                if attribute(kAXRoleAttribute, of: element) as? String == kAXButtonRole {
                    for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                        if let label = attribute(key, of: element) as? String {
                            buttons[label.lowercased()] = element
                        }
                    }
                }
                if (buttons["lap"] != nil && buttons["stop"] != nil)
                    || (buttons["reset"] != nil && buttons["start"] != nil),
                   let target = buttons[command.rawValue.lowercased()] {
                    return AXUIElementPerformAction(target, kAXPressAction as CFString) == .success
                }
                queue.append(contentsOf: attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? [])
            }
            // Require the stopwatch's paired controls before pressing a generic label.
            guard (buttons["lap"] != nil && buttons["stop"] != nil)
                || (buttons["reset"] != nil && buttons["start"] != nil),
                let button = buttons[command.rawValue.lowercased()] else { continue }
            return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func openClock() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.clock") else { return }
        closeNotch()
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    private func renderNotch(animationDuration: TimeInterval = 0) {
        guard !isLocked, sessionActive, screenAwake, let screen = preferredScreen else {
            notchHover.isHighlighted = false
            notch.orderOut(nil)
            return
        }

        let floating = floatingNotch || screen.safeAreaInsets.top == 0
        if !floating, menuClearance?.compact == false {
            if tuckTask == nil { notch.orderOut(nil) }
            return
        }
        let shouldCastShadow = glassNotch && expanded && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if notch.hasShadow != shouldCastShadow { notch.hasShadow = shouldCastShadow }
        let topHeight = floating ? 32 : screen.safeAreaInsets.top
        let camera = cameraGeometry(for: screen)
        let clockVisible = showingClockPage
        let compactClearance = menuClearance?.expandedWidth ?? 390
        let clockWidth = camera.width + 102
        let clockFits = clockVisible && (floating || compactClearance >= clockWidth)
        let compactWidth = floating ? 132 : camera.width + (clockFits ? 102 : 74)
        let hovered = !expanded && notchHover.isHighlighted
        let targetWidth: CGFloat = fullNotch ? 475 : 390
        let expandedWidth = floating ? targetWidth : min(targetWidth, compactClearance + 2 * NotchShape.expandedShoulder)
        let width = min(expanded ? expandedWidth : compactWidth + (hovered && !clockVisible ? 8 : 0), screen.frame.width - 24)
        let expandedHeight: CGFloat = fullNotch ? 216 : 184
        let height = topHeight + (expanded ? expandedHeight : (hovered ? 2 : 0))
        let top = floating ? screen.visibleFrame.maxY - 5 : screen.frame.maxY
        let center = camera.center
        let frame = CGRect(x: center - width / 2, y: top - height, width: width, height: height)
        let view = NotchView(playback: playback, topHeight: hovered ? height : topHeight, floating: floating,
                             expanded: expanded, clockActivities: clockActivities, compactClockFits: clockFits,
                             openClock: { [weak self] in self?.openClock() },
                             selectMusicPage: { [weak self] in self?.selectMusicPage($0) },
                             stopwatchCommand: { [weak self] in self?.sendStopwatchCommand($0) },
                             full: fullNotch,
                             glass: glassNotch, pages: notchPages,
                             toggleFull: { [weak self] in
                                 guard let self else { return }
                                 self.fullNotch.toggle()
                                 self.renderNotch(animationDuration: 0.24)
                             },
                             hover: notchHover, open: { [weak self] in self?.openNotchFromClick() },
                             openArtwork: { [weak self] in
                                 guard let self, !self.playback.preview else { return }
                                 self.closeNotch()
                                 self.playback.openPlayer()
                             },
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
        if frame != notch.frame, animationDuration > 0, notch.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                notch.animator().setFrame(frame, display: true)
            }
        } else if frame != notch.frame {
            notch.setFrame(frame, display: true)
        }
        if !expanded, notch.isKeyWindow { notch.resignKey() }
        notch.keyboardEnabled = expanded
        if !notch.isVisible { notch.orderFrontRegardless() }
        if expanded, !notch.isKeyWindow { notch.makeKey() }
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
        fullNotch = false
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
        let width = min(artwork.mode == .lyrics ? 750 : 420, screen.frame.width - 32)
        let maximumHeight = screen.frame.height * 0.52
        let artSize = max(64, min(artwork.mode == .record ? 186 : 276, maximumHeight - 155, width * 0.43 + (artwork.mode == .lyrics ? 0 : 90)))
        let height = min(maximumHeight, artSize + (preview ? 138 : 118))
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2,
                           width: width, height: height)
        if panel.contentView == nil || panel.frame.size != frame.size {
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
        clockPoll?.invalidate()
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

    @objc private func toggleGlassNotch() {
        glassNotch.toggle()
        UserDefaults.standard.set(glassNotch, forKey: "glassNotch")
        renderNotch()
        buildMenu()
    }

    @objc private func toggleFloatingNotch() {
        floatingNotch.toggle()
        UserDefaults.standard.set(floatingNotch, forKey: "floatingNotch")
        refreshMenuClearance(force: true)
        renderNotch(animationDuration: 0.24)
        buildMenu()
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
        let glass = menu.addItem(withTitle: "Glass Notch", action: #selector(toggleGlassNotch), keyEquivalent: "")
        glass.state = glassNotch ? .on : .off
        let floating = menu.addItem(withTitle: "Floating Notch", action: #selector(toggleFloatingNotch), keyEquivalent: "")
        floating.state = floatingNotch || preferredScreen?.safeAreaInsets.top == 0 ? .on : .off
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
