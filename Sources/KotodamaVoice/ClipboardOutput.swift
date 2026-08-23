import AppKit

enum ClipboardOutputError: Error, Equatable {
    case writeFailed
    case verificationFailed
}

@MainActor
protocol PasteboardAccessing: AnyObject {
    func replaceString(_ value: String) -> Bool
    func readString() -> String?
}

@MainActor
final class SystemPasteboard: PasteboardAccessing {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func replaceString(_ value: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }

    func readString() -> String? {
        pasteboard.string(forType: .string)
    }
}

@MainActor
final class ClipboardOutput {
    private let pasteboard: PasteboardAccessing

    init(pasteboard: PasteboardAccessing = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    func write(_ text: String) throws {
        guard pasteboard.replaceString(text) else {
            throw ClipboardOutputError.writeFailed
        }
        guard pasteboard.readString() == text else {
            throw ClipboardOutputError.verificationFailed
        }
    }
}
