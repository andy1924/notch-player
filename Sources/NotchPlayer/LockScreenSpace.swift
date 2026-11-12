import AppKit

/// Uses the same WindowServer presentation mechanism documented by SkyLightWindow.
/// Resolve it at runtime so a missing symbol leaves the AppKit presentation available.
final class LockScreenSpace {
    private typealias GetConnection = @convention(c) () -> Int32
    private typealias CreateSpace = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    // These calls do not expose a reliable status, including on macOS 27.
    private typealias SetVisibility = @convention(c) (Int32, CFArray) -> Void
    private typealias MoveWindow = @convention(c) (Int32, Int32, CFArray, Int32) -> Void

    private let library: UnsafeMutableRawPointer
    private let connection: Int32
    private let space: Int32
    private let showSpaces: SetVisibility
    private let hideSpaces: SetVisibility
    private let moveWindow: MoveWindow

    init?() {
        guard let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY) else {
            return nil
        }
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            dlsym(library, name).map { unsafeBitCast($0, to: type) }
        }
        guard let getConnection = symbol("SLSMainConnectionID", as: GetConnection.self),
              let create = symbol("SLSSpaceCreate", as: CreateSpace.self),
              let setLevel = symbol("SLSSpaceSetAbsoluteLevel", as: SetLevel.self),
              let show = symbol("SLSShowSpaces", as: SetVisibility.self),
              let hide = symbol("SLSHideSpaces", as: SetVisibility.self),
              let move = symbol("SLSSpaceAddWindowsAndRemoveFromSpaces", as: MoveWindow.self) else {
            dlclose(library)
            return nil
        }
        let connection = getConnection()
        let space = create(connection, 1, 0)
        // The Notification Center space level permits a window to appear during lock.
        guard space > 0, setLevel(connection, space, 400) == 0 else {
            dlclose(library)
            return nil
        }
        self.library = library
        self.connection = connection
        self.space = space
        showSpaces = show
        hideSpaces = hide
        moveWindow = move
    }

    @MainActor
    func show(_ window: NSWindow) {
        let number = window.windowNumber
        guard number > 0 else { return }
        // Both operations may need to be reapplied when display wake rebuilds the visible spaces.
        showSpaces(connection, [space] as CFArray)
        moveWindow(connection, space, [number] as CFArray, 7)
    }

    func hide() {
        hideSpaces(connection, [space] as CFArray)
    }

    deinit {
        hide()
        dlclose(library)
    }
}
