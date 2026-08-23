import AppKit
import Carbon.HIToolbox
import KotodamaCore
import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    let descriptor: HotKeyDescriptor
    let onChange: (HotKeyDescriptor) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onChange = onChange
        view.descriptor = descriptor
        return view
    }

    func updateNSView(_ view: ShortcutRecorderView, context: Context) {
        view.onChange = onChange
        view.descriptor = descriptor
    }
}

final class ShortcutRecorderView: NSView {
    var onChange: ((HotKeyDescriptor) -> Void)?
    var descriptor = AppRuntime.defaultHotKey {
        didSet { needsDisplay = true }
    }

    private var isRecording = false {
        didSet { needsDisplay = true }
    }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 220, height: 28) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        let newDescriptor = HotKeyDescriptor(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
        isRecording = false
        onChange?(newDescriptor)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.12) : .controlBackgroundColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : .separatorColor).setStroke()
        path.stroke()

        let text = isRecording ? "新しいショートカットを入力" : displayName(for: descriptor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
            withAttributes: attributes
        )
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    private func displayName(for descriptor: HotKeyDescriptor) -> String {
        var parts: [String] = []
        if descriptor.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if descriptor.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if descriptor.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if descriptor.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        parts.append(keyName(for: descriptor.keyCode))
        return parts.joined()
    }

    private func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            guard let event = CGEvent(
                keyboardEventSource: nil,
                virtualKey: CGKeyCode(keyCode),
                keyDown: true
            ).flatMap(NSEvent.init(cgEvent:)),
                let characters = event.charactersIgnoringModifiers,
                !characters.isEmpty
            else {
                return "Key \(keyCode)"
            }
            return characters.uppercased()
        }
    }
}
