import AppKit
import Carbon.HIToolbox
import SwiftUI

enum LiveAssistantShortcutFormatting {
    static func label(keyCode: Int, modifiers: Int) -> String {
        var result = ""
        if modifiers & Int(cmdKey) != 0 { result += "⌘" }
        if modifiers & Int(optionKey) != 0 { result += "⌥" }
        if modifiers & Int(controlKey) != 0 { result += "⌃" }
        if modifiers & Int(shiftKey) != 0 { result += "⇧" }
        return result + keyLabel(keyCode: keyCode)
    }

    static func carbonModifiers(for flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func keyLabel(keyCode: Int) -> String {
        let keys: [Int: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
            38: "J", 40: "K", 45: "N", 46: "M", 18: "1", 19: "2", 20: "3",
            21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
            49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        ]
        return keys[keyCode] ?? "Key \(keyCode)"
    }
}

/// Global shortcut registration uses Carbon so the assistant can open while
/// another meeting app is active. The shortcut must include Command, Option,
/// or Control to avoid intercepting ordinary typing.
@MainActor
final class LiveAssistantShortcutMonitor {
    nonisolated(unsafe) private var hotKey: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed),
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            liveAssistantShortcutEventHandler,
            1,
            &eventType,
            nil,
            &eventHandler,
        )
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    @discardableResult
    func register(keyCode: Int, modifiers: Int) -> Bool {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        guard modifiers & (Int(cmdKey) | Int(optionKey) | Int(controlKey)) != 0 else { return false }

        let identifier = EventHotKeyID(signature: OSType(0x53575449), id: 1)
        var registered: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(keyCode),
            UInt32(modifiers),
            identifier,
            GetApplicationEventTarget(),
            0,
            &registered,
        )
        guard status == noErr else { return false }
        hotKey = registered
        return true
    }
}

private func liveAssistantShortcutEventHandler(
    _: EventHandlerCallRef?,
    _: EventRef?,
    _: UnsafeMutableRawPointer?,
) -> OSStatus {
    DispatchQueue.main.async {
        NotificationCenter.default.post(name: .showLiveAssistant, object: nil)
    }
    return noErr
}

struct LiveAssistantShortcutRecorder: NSViewRepresentable {
    @Binding var keyCode: Int
    @Binding var modifiers: Int
    @Binding var isRegistered: Bool

    func makeNSView(context _: Context) -> AssistantShortcutCaptureView {
        let view = AssistantShortcutCaptureView(frame: .zero)
        view.onCapture = { capturedKeyCode, capturedModifiers in
            keyCode = Int(capturedKeyCode)
            modifiers = Int(capturedModifiers)
        }
        return view
    }

    func updateNSView(_ view: AssistantShortcutCaptureView, context _: Context) {
        view.shortcutLabel = LiveAssistantShortcutFormatting.label(keyCode: keyCode, modifiers: modifiers)
        view.statusLabel = isRegistered ? "" : "Unavailable"
        view.needsDisplay = true
        view.onCapture = { capturedKeyCode, capturedModifiers in
            keyCode = Int(capturedKeyCode)
            modifiers = Int(capturedModifiers)
        }
    }
}

final class AssistantShortcutCaptureView: NSView {
    var onCapture: ((UInt32, UInt32) -> Void)?
    var shortcutLabel = "⌘⇧A"
    var statusLabel = ""
    private var isCapturing = false

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        _ = event
        isCapturing = true
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { return super.keyDown(with: event) }
        if event.keyCode == UInt16(kVK_Escape) {
            isCapturing = false
            needsDisplay = true
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let carbonModifiers = LiveAssistantShortcutFormatting.carbonModifiers(for: modifiers)
        guard carbonModifiers & (UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)) != 0 else {
            NSSound.beep()
            return
        }
        onCapture?(UInt32(event.keyCode), carbonModifiers)
        isCapturing = false
        needsDisplay = true
    }

    override func cancelOperation(_: Any?) {
        isCapturing = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isCapturing ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.controlBackgroundColor)
            .setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = isCapturing ? 2 : 1
        path.stroke()

        let title = isCapturing ? "Press a shortcut…" : shortcutLabel
        let color = statusLabel.isEmpty ? NSColor.labelColor : NSColor.systemRed
        let text = NSAttributedString(
            string: statusLabel.isEmpty ? title : statusLabel,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color],
        )
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}
