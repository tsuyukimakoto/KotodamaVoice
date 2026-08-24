import Foundation
import Testing
@testable import KotodamaVoice

@Test @MainActor
func autoInsertWriterReplacesOnlyTheCapturedSelection() async throws {
    let access = AutoInsertTextAccessSpy(
        value: "音声入力の前後を残します",
        selection: TextSelectionRange(location: 4, length: 2)
    )
    let writer = AutoInsertTextWriter(access: access)
    let target = writableTarget(selection: access.selection)

    try await writer.replaceSelection(with: "結果", in: target)

    #expect(access.value == "音声入力結果後を残します")
    #expect(access.pasteCount == 1)
    #expect(access.selection == TextSelectionRange(location: 6, length: 0))
}

@Test @MainActor
func autoInsertWriterUsesAccessibilityUTF16Ranges() async throws {
    let access = AutoInsertTextAccessSpy(
        value: "A😀BC",
        selection: TextSelectionRange(location: 1, length: 2)
    )
    let writer = AutoInsertTextWriter(access: access)

    try await writer.replaceSelection(
        with: "声",
        in: writableTarget(selection: access.selection)
    )

    #expect(access.value == "A声BC")
    #expect(access.selection == TextSelectionRange(location: 2, length: 0))
}

@Test @MainActor
func autoInsertWriterDoesNotWriteAfterASelectionChange() async {
    let access = AutoInsertTextAccessSpy(
        value: "既存の入力",
        selection: TextSelectionRange(location: 3, length: 0)
    )
    let writer = AutoInsertTextWriter(access: access)
    let captured = writableTarget(
        selection: TextSelectionRange(location: 0, length: 0)
    )

    await #expect(throws: AutoInsertTextWriterError.selectionChanged) {
        try await writer.replaceSelection(with: "結果", in: captured)
    }
    #expect(access.value == "既存の入力")
    #expect(access.pasteCount == 0)
}

@Test @MainActor
func autoInsertWriterPropagatesPasteActionFailure() async {
    let access = AutoInsertTextAccessSpy(
        value: "既存の入力",
        selection: TextSelectionRange(location: 0, length: 0)
    )
    access.pasteError = AutoInsertTextWriterError.pasteActionUnavailable
    let writer = AutoInsertTextWriter(access: access)

    await #expect(throws: AutoInsertTextWriterError.pasteActionUnavailable) {
        try await writer.replaceSelection(
            with: "結果",
            in: writableTarget(selection: access.selection)
        )
    }
    #expect(access.value == "既存の入力")
}

@Test @MainActor
func autoInsertWriterVerifiesTheWrittenValue() async {
    let access = AutoInsertTextAccessSpy(
        value: "既存の入力",
        selection: TextSelectionRange(location: 0, length: 0)
    )
    access.ignoresPaste = true
    let writer = AutoInsertTextWriter(access: access)

    await #expect(throws: AutoInsertTextWriterError.verificationFailed) {
        try await writer.replaceSelection(
            with: "結果",
            in: writableTarget(selection: access.selection)
        )
    }
}

@Test @MainActor
func systemTextAccessWritesClipboardThenInvokesPasteForCapturedProcess() throws {
    let pasteboard = AutoInsertPasteboardSpy()
    let command = AutoInsertPasteCommandSpy()
    let access = SystemAutoInsertTextAccess(
        clipboard: ClipboardOutput(pasteboard: pasteboard),
        pasteCommand: command
    )
    let target = writableTarget(
        selection: TextSelectionRange(location: 0, length: 0)
    )

    try access.paste("結果", into: target)

    #expect(pasteboard.value == "結果")
    #expect(command.processIDs == [100])
}

@Test @MainActor
func systemTextAccessDoesNotInvokePasteWhenClipboardWriteFails() {
    let pasteboard = AutoInsertPasteboardSpy()
    pasteboard.acceptsWrites = false
    let command = AutoInsertPasteCommandSpy()
    let access = SystemAutoInsertTextAccess(
        clipboard: ClipboardOutput(pasteboard: pasteboard),
        pasteCommand: command
    )

    #expect(throws: AutoInsertTextWriterError.pasteboardWriteFailed) {
        try access.paste(
            "結果",
            into: writableTarget(
                selection: TextSelectionRange(location: 0, length: 0)
            )
        )
    }
    #expect(command.processIDs.isEmpty)
}

@MainActor
private final class AutoInsertTextAccessSpy: AutoInsertTextAccessing {
    var value: String
    var selection: TextSelectionRange
    var ignoresPaste = false
    var pasteError: AutoInsertTextWriterError?
    private(set) var pasteCount = 0

    init(
        value: String,
        selection: TextSelectionRange
    ) {
        self.value = value
        self.selection = selection
    }

    func readValue(from element: AutoInsertElementReference) throws -> String {
        value
    }

    func readSelection(
        from element: AutoInsertElementReference
    ) throws -> TextSelectionRange {
        selection
    }

    func paste(
        _ replacement: String,
        into target: AutoInsertTargetObservation
    ) throws {
        pasteCount += 1
        if let pasteError {
            throw pasteError
        }
        if !ignoresPaste {
            let range = NSRange(
                location: selection.location,
                length: selection.length
            )
            value = (value as NSString).replacingCharacters(
                in: range,
                with: replacement
            )
            selection = TextSelectionRange(
                location: range.location + (replacement as NSString).length,
                length: 0
            )
        }
    }
}

@MainActor
private final class AutoInsertPasteboardSpy: PasteboardAccessing {
    var value: String?
    var acceptsWrites = true

    func replaceString(_ value: String) -> Bool {
        guard acceptsWrites else {
            return false
        }
        self.value = value
        return true
    }

    func readString() -> String? {
        value
    }
}

@MainActor
private final class AutoInsertPasteCommandSpy: AutoInsertPasteCommandPerforming {
    private(set) var processIDs: [Int32] = []

    func performPaste(into target: AutoInsertTargetObservation) throws {
        processIDs.append(target.processID)
    }
}

private func writableTarget(
    selection: TextSelectionRange
) -> AutoInsertTargetObservation {
    AutoInsertTargetObservation(
        processID: 100,
        element: AutoInsertElementReference(testID: "element"),
        role: "AXTextArea",
        isEditable: true,
        selection: selection
    )
}
