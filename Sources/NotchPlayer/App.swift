import AppKit
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

private final class PlayerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
    override func mouseExited(with event: NSEvent) { hoverChanged?(false) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class LockHostingView: NSHostingView<LockCard> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate {
    private let playback = Playback(preview: CommandLine.arguments.contains("--demo"))
    private let notch = PlayerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
    private var lockCard: PlayerPanel?
    private var previewCard: PlayerPanel?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        configure(notch, level: NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Notch Player")
        buildMenu()

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(didLock), name: .init("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(didUnlock), name: .init("com.apple.screenIsUnlocked"), object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(screenDidSleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(screenDidWake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidResign), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        workspace.addObserver(self, selector: #selector(sessionDidActivate), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.expanded, !self.notch.frame.contains(NSEvent.mouseLocation) else { return }
                self.closeNotch()
            }
        }
        lockPoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkLockPresentation() }
        }
        playback.didUpdate = { [weak self] in self?.updateLockCard() }
        reconcileLock()
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

    private func renderNotch(animated: Bool = false) {
        guard !isLocked, sessionActive, screenAwake, let screen = preferredScreen else {
            notchHover.isHighlighted = false
            notch.orderOut(nil)
            return
        }

        let floating = screen.safeAreaInsets.top == 0
        let topHeight = floating ? 32 : screen.safeAreaInsets.top
        let left = screen.auxiliaryTopLeftArea?.width ?? 0
        let right = screen.auxiliaryTopRightArea?.width ?? 0
        let cameraWidth = left > 0 && right > 0 ? screen.frame.width - left - right : 180
        let center = left > 0 && right > 0 ? screen.frame.minX + left + cameraWidth / 2 : screen.frame.midX
        let width = expanded ? min(390, screen.frame.width - 24) : (floating ? 132 : cameraWidth + 64)
        let height = topHeight + (expanded ? 140 : 0)
        let top = floating ? screen.visibleFrame.maxY - 5 : screen.frame.maxY
        let frame = CGRect(x: center - width / 2, y: top - height, width: width, height: height)
        let view = NotchView(playback: playback, topHeight: topHeight, floating: floating,
                             expanded: expanded, hover: notchHover, toggle: { [weak self] in self?.toggleNotch() })
        if let hoverView {
            hoverView.rootView = view
        } else {
            let hosting = HoverView(rootView: view)
            hosting.sizingOptions = []
            hosting.hoverChanged = { [weak self] inside in self?.notchHover.isHighlighted = inside }
            notch.contentView = hosting
            hoverView = hosting
        }
        if animated, notch.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                notch.animator().setFrame(frame, display: true)
            }
        } else {
            notch.setFrame(frame, display: true)
        }
        if !notch.isVisible { notch.orderFrontRegardless() }
    }

    private func toggleNotch() {
        expanded.toggle()
        renderNotch(animated: true)
    }

    private func closeNotch(animated: Bool = true) {
        expanded = false
        renderNotch(animated: animated)
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

        let width = min(376, screen.frame.width - 32)
        let artSize: CGFloat = screen.frame.height >= 820 ? 152 : 110
        let height = artSize + (preview ? 156 : 136)
        let frame = CGRect(x: screen.frame.midX - width / 2, y: screen.frame.midY - height / 2,
                           width: width, height: height)
        if panel.contentView == nil || panel.frame.height != frame.height {
            let hosting = LockHostingView(rootView: LockCard(playback: playback, preview: preview,
                                                             artSize: artSize, artwork: LockArtwork()))
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
            closeNotch(animated: false)
            playback.refresh()
        } else {
            renderNotch()
        }
        buildMenu()
        updateLockCard()
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
        renderNotch()
        updateLockCard()
        refreshLockPresentation()
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
        guard !expanded else { return }
        expanded = true
        renderNotch(animated: true)
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Notch Player", action: #selector(showNotch), keyEquivalent: "")
        menu.addItem(withTitle: lockPreview ? "Close Lock Screen Preview" : "Preview Lock Screen",
                     action: #selector(toggleLockPreview), keyEquivalent: "")
        let lock = menu.addItem(withTitle: "Show on Lock Screen", action: #selector(toggleLockEnabled),
                                keyEquivalent: "")
        lock.state = lockEnabled ? .on : .off
        menu.items.forEach { $0.target = self }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Notch Player", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q")
        quit.target = NSApp
        statusItem?.menu = menu
    }
}
