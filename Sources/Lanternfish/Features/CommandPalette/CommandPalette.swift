import AppKit
import LanternfishKit
import SwiftUI

/// ⌘K quick search / command palette, shown as an overlay near the top of the main window.
/// Also hosts the window's transient toasts ("Magic packet sent", "Copied …").
///
/// Keys: ↑/↓ (or ⌃P/⌃N) move, ↩ runs, ⌘↩ runs the secondary action, ⇥ or → opens the
/// selected item's actions, ← / ⌫ (empty field) / Esc go back, Esc closes, ⌘K toggles.
///
/// Debug aid: LANTERNFISH_PALETTE=<query> opens the palette with that query 2 s after launch;
/// LANTERNFISH_PALETTE_ACTIONS=1 then opens the top result's actions.
private struct CommandPaletteModifier: ViewModifier {
    let hub: NetworkHub
    @State private var model: CommandPaletteModel?
    @State private var window: NSWindow?
    @State private var monitor: Any?
    @Bindable private var router = Router.shared
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                ZStack(alignment: .top) {
                    if router.showCommandPalette, let model {
                        Color.black.opacity(0.12)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                            .transition(.opacity)
                        CommandPalettePanel(model: model)
                            .padding(.top, 56)
                            .transition(
                                .asymmetric(
                                    insertion: .scale(scale: 0.97, anchor: .top).combined(with: .opacity),
                                    removal: .opacity)
                            )
                            .onChange(of: deviceSignature) { model.rebuildIndex() }
                    }
                }
                .animation(.snappy(duration: 0.18), value: router.showCommandPalette)
            }
            .overlay(alignment: .bottom) { PaletteToastView() }
            .healthSheet(hub: hub)
            .background {
                WindowVisibilityReader { w, _ in
                    if w !== window { DispatchQueue.main.async { window = w } }
                }
            }
            .sheet(item: Binding(get: { model?.hostPing }, set: { model?.hostPing = $0 })) { target in
                HostPingSheet(target: target)
            }
            .onChange(of: router.showCommandPalette) { _, shown in
                shown ? opened() : closed()
            }
            .onAppear {
                if model == nil { model = CommandPaletteModel(hub: hub) }
                if router.showCommandPalette { opened() }
                runDebugHook()
            }
            .onDisappear { removeMonitor() }
    }

    /// Changes when any network's device list changes while the palette is open.
    private var deviceSignature: [Int] {
        hub.stores.map { $0.devices.count &* 31 &+ $0.onlineCount }
    }

    private func opened(query: String = "") {
        guard let model else { return }
        // Ignore ⌘K while a sheet is up; the palette would sit behind it.
        if window?.attachedSheet != nil {
            router.showCommandPalette = false
            return
        }
        model.openSettings = { openSettings() }
        model.close = { close() }
        model.prepare(query: query)
        installMonitor()
    }

    private func closed() {
        removeMonitor()
        // Hand focus back to the window's content (the table) instead of leaving it nowhere.
        if let window, window.firstResponder is NSTextView {
            window.makeFirstResponder(nil)
        }
    }

    private func close() {
        router.showCommandPalette = false
    }

    private func runDebugHook() {
        let env = DebugEnv.values
        guard let q = env["LANTERNFISH_PALETTE"], !Self.ranDebugHook else { return }
        Self.ranDebugHook = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            router.showCommandPalette = true
            try? await Task.sleep(for: .milliseconds(50))
            model?.query = q
            if env["LANTERNFISH_PALETTE_ACTIONS"] == "1" || env["LANTERNFISH_PALETTE_KEYS"] != nil {
                // Give the scan a moment so the top result is a real device.
                try? await Task.sleep(for: .seconds(8))
                model?.rebuildIndex()
            }
            if env["LANTERNFISH_PALETTE_ACTIONS"] == "1" { model?.showActions() }
            if let keys = env["LANTERNFISH_PALETTE_KEYS"] { await replay(keys) }
        }
    }

    /// Debug aid: LANTERNFISH_PALETTE_KEYS="down,tab,text:wake,return" posts those keys through the
    /// app's event path (so the key monitor handles them), 300 ms apart.
    @MainActor
    private func replay(_ keys: String) async {
        let codes: [String: (UInt16, NSEvent.ModifierFlags)] = [
            "up": (KeyCode.up, []), "down": (KeyCode.down, []), "left": (KeyCode.left, []),
            "right": (KeyCode.right, []), "tab": (KeyCode.tab, []), "return": (KeyCode.return, []),
            "cmdreturn": (KeyCode.return, .command), "esc": (KeyCode.escape, []), "delete": (KeyCode.delete, []),
        ]
        for key in keys.split(separator: ",").map(String.init) {
            try? await Task.sleep(for: .milliseconds(300))
            if key.hasPrefix("text:") {
                model?.query = String(key.dropFirst(5))
                continue
            }
            guard let (code, mods) = codes[key], let window,
                let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: mods,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: "", charactersIgnoringModifiers: "",
                    isARepeat: false, keyCode: code)
            else { continue }
            NSApp.sendEvent(event)
        }
    }

    @MainActor private static var ranDebugHook = false

    // MARK: Keys

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let e = event
            let consumed = MainActor.assumeIsolated { handle(e) }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// True when the key was consumed.
    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        guard router.showCommandPalette, let model, let window, event.window === window,
            window.attachedSheet == nil
        else { return false }
        // Let input methods finish composing (Return confirms a candidate there).
        if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = mods.contains(.command)
        let ctrl = mods.contains(.control)
        switch event.keyCode {
        case KeyCode.up:
            model.moveSelection(-1)
            return true
        case KeyCode.down:
            model.moveSelection(1)
            return true
        case KeyCode.pageUp:
            model.moveSelection(-8)
            return true
        case KeyCode.pageDown:
            model.moveSelection(8)
            return true
        case KeyCode.return, KeyCode.enter:
            cmd ? model.runSecondary() : model.runSelected()
            return true
        case KeyCode.tab:
            if mods.contains(.shift) {
                model.leaveActions()
                return true
            }
            if !model.showActions() { NSSound.beep() }
            return true
        case KeyCode.right:
            guard model.actionsTarget == nil, caretAtEnd(window) else { return false }
            return model.showActions()
        case KeyCode.left, KeyCode.delete:
            guard model.actionsTarget != nil, model.query.isEmpty else { return false }
            return model.leaveActions()
        case KeyCode.escape:
            if model.leaveActions() { return true }
            if !model.query.isEmpty {
                model.query = ""
                return true
            }
            close()
            return true
        default:
            break
        }
        if ctrl, let c = event.charactersIgnoringModifiers?.lowercased() {
            if c == "n" {
                model.moveSelection(1)
                return true
            }
            if c == "p" {
                model.moveSelection(-1)
                return true
            }
        }
        if cmd, event.charactersIgnoringModifiers?.lowercased() == "k" {
            close()
            return true
        }
        return false
    }

    /// → opens actions only when it can't move the caret any further.
    @MainActor
    private func caretAtEnd(_ window: NSWindow) -> Bool {
        guard let editor = window.firstResponder as? NSTextView else { return true }
        let r = editor.selectedRange()
        return r.length == 0 && r.location >= (editor.string as NSString).length
    }
}

/// Virtual key codes (`NSEvent.keyCode`) the palette handles.
private enum KeyCode {
    static let `return`: UInt16 = 36
    static let tab: UInt16 = 48
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let enter: UInt16 = 76
    static let pageUp: UInt16 = 116
    static let pageDown: UInt16 = 121
    static let left: UInt16 = 123
    static let right: UInt16 = 124
    static let down: UInt16 = 125
    static let up: UInt16 = 126
}

extension View {
    func commandPalette(hub: NetworkHub) -> some View { modifier(CommandPaletteModifier(hub: hub)) }
}

// MARK: - Toasts

/// Short-lived messages at the bottom of the main window.
@MainActor
@Observable
final class PaletteToastCenter {
    static let shared = PaletteToastCenter()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let detail: String?
        let symbol: String
        let isError: Bool
    }

    private(set) var current: Toast?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    func show(
        _ title: String, detail: String? = nil, symbol: String = "checkmark.circle.fill",
        isError: Bool = false
    ) {
        let toast = Toast(title: title, detail: detail, symbol: symbol, isError: isError)
        current = toast
        AccessibilityNotification.Announcement(detail.map { "\(title). \($0)" } ?? title).post()
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(isError ? 5 : detail == nil ? 1.6 : 3.2))
            guard !Task.isCancelled, self?.current?.id == toast.id else { return }
            self?.current = nil
        }
    }

    func dismiss() { current = nil }
}

private struct PaletteToastView: View {
    private let center = PaletteToastCenter.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if let toast = center.current {
                HStack(spacing: 10) {
                    Image(systemName: toast.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(toast.isError ? Color.orange : Color.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title).font(.callout.weight(.medium))
                        if let detail = toast.detail {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background {
                    ZStack {
                        if reduceTransparency {
                            Capsule().fill(Color(nsColor: .windowBackgroundColor))
                        } else {
                            Capsule().fill(.thickMaterial)
                            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.75))
                        }
                    }
                }
                .overlay { Capsule().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.bottom, 22)
                .onTapGesture { center.dismiss() }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.spring(duration: 0.3), value: center.current)
    }
}

// MARK: - Ping sheet for typed addresses

/// "Ping 1.2.3.4" for an address that isn't a listed device: a small live ping sheet.
private struct HostPingSheet: View {
    let target: HostPingTarget
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.green)
                Text("Ping \(target.ip.description)").font(.headline)
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            Form {
                if let session = target.store.pingSessions[target.ip] {
                    PingSection(ip: target.ip, session: session, store: target.store)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 400, height: 380)
        .onDisappear { target.store.stopPing(target.ip) }
    }
}
