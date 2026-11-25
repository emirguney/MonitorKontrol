import AppKit

/// Owns the single, reusable control window opened from the Dock icon.
/// The window is hidden (not released) on close so reopening keeps its state and position.
@MainActor
final class ControlWindowController {
    private static let autosaveName = "MonitorKontrolControlWindow"
    private static let initialContentSize = NSSize(width: 360, height: 520)

    private let makeContentController: () -> NSViewController
    private var window: NSWindow?

    init(makeContentController: @escaping () -> NSViewController) {
        self.makeContentController = makeContentController
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let contentController = makeContentController()
        let window = NSWindow(contentViewController: contentController)
        window.title = "MonitorKontrol"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.setContentSize(Self.initialContentSize)

        if !window.setFrameUsingName(Self.autosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.autosaveName)
        return window
    }
}
