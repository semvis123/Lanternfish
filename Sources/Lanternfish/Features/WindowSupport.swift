import AppKit
import SwiftUI

extension NSWindow {
    /// On screen: neither minimized nor fully covered by other windows.
    var isVisibleOnScreen: Bool { occlusionState.contains(.visible) && !isMiniaturized }

    /// Debug aid for the LANTERNFISH_*_SNAPSHOT hooks: writes a PNG of the whole window, title bar included.
    func writeSnapshot(to path: String) {
        guard let view = contentView?.superview ?? contentView,
            let png = UISnapshot.snapshot(view, scale: backingScaleFactor)?.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Calls a handler whenever a window is minimized, restored, covered or uncovered.
@MainActor
final class WindowVisibilityObserver {
    private var observers: [NSObjectProtocol] = []

    /// Replaces any previous observation; nil just stops observing.
    func observe(_ window: NSWindow?, onChange: @escaping @MainActor () -> Void) {
        stop()
        guard let window else { return }
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { onChange() }
                })
        }
    }

    func stop() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    isolated deinit { stop() }
}

/// Reports the hosting window and whether it is visible on screen (see `NSWindow.isVisibleOnScreen`).
struct WindowVisibilityReader: NSViewRepresentable {
    var onChange: @MainActor (NSWindow?, Bool) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: (@MainActor (NSWindow?, Bool) -> Void)?
        private let visibility = WindowVisibilityObserver()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            visibility.observe(window) { [weak self] in self?.report() }
            guard let window else {
                onChange?(nil, false)
                return
            }
            onChange?(window, window.isVisibleOnScreen)
        }

        private func report() {
            guard let window else { return }
            onChange?(window, window.isVisibleOnScreen)
        }
    }
}
