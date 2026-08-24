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

@Test(
    "Auto Insertの再検証失敗は既存入力を変更せずClipboardへFallbackする",
    arguments: [
        OutputFallbackFailure.unsafeElement,
        .permissionRevoked,
        .targetApplicationTerminated,
    ]
)
@MainActor
private func outputDeliveryFallsBackWithoutInvokingAutoInsert(
    failure: OutputFallbackFailure
) async throws {
    let clipboard = ClipboardWriterSpy()
    let target = OutputTargetCoordinatorSpy(error: failure.error)
    let writer = AutoInsertWriterSpy()
    let delivery = OutputDeliveryCoordinator(
        clipboard: clipboard,
        autoInsertTarget: target,
        autoInsertWriter: writer
    )

    let outcome = try await delivery.deliver(
        "Fallback結果",
        mode: .autoInsert,
        usedFormattingFallback: false
    )

    #expect(outcome == .automaticInsertionFellBackToClipboard)
    #expect(clipboard.values == ["Fallback結果"])
    #expect(writer.replacements.isEmpty)
    #expect(target.clearCount == 1)
}

@Test(
    "Auto Insertの失敗は段階を区別して本文なしで記録する",
    arguments: [
        AutoInsertDiagnosticFixture(
            error: AutoInsertTargetObservationError.noFrontmostApplication,
            stage: .focusedApplication,
            diagnosticError: .noFrontmostApplication
        ),
        AutoInsertDiagnosticFixture(
            error: AutoInsertTargetValidationError.selectionChanged,
            stage: .targetRevalidation,
            diagnosticError: .selectionChanged
        ),
        AutoInsertDiagnosticFixture(
            error: AutoInsertTextWriterError.pasteActionUnavailable,
            stage: .pasteMenuItem,
            diagnosticError: .pasteActionUnavailable
        ),
        AutoInsertDiagnosticFixture(
            error: AutoInsertTextWriterError.verificationFailed,
            stage: .resultVerification,
            diagnosticError: .verificationFailed
        ),
    ]
)
@MainActor
private func outputDeliveryRecordsTypedAutoInsertFailure(
    fixture: AutoInsertDiagnosticFixture
) async throws {
    let clipboard = ClipboardWriterSpy()
    let target = OutputTargetCoordinatorSpy(error: fixture.error)
    let writer = AutoInsertWriterSpy()
    let logger = DebugErrorLoggerSpy()
    let delivery = OutputDeliveryCoordinator(
        clipboard: clipboard,
        autoInsertTarget: target,
        autoInsertWriter: writer,
        debugLogger: logger
    )

    _ = try await delivery.deliver(
        "本文_CANARY",
        mode: .autoInsert,
        usedFormattingFallback: false,
        requestID: nil
    )

    let event = try #require(logger.events.first)
    #expect(event.area == .autoInsert)
    #expect(event.stage == fixture.stage)
    #expect(event.error == fixture.diagnosticError)
    #expect(!String(describing: event).contains("本文_CANARY"))
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

private enum OutputFallbackFailure: CaseIterable {
    case unsafeElement
    case permissionRevoked
    case targetApplicationTerminated

    var error: Error {
        switch self {
        case .unsafeElement:
            AutoInsertTargetValidationError.elementNotEditable
        case .permissionRevoked:
            AutoInsertTargetObservationError.accessibilityError(-25_211)
        case .targetApplicationTerminated:
            AutoInsertTargetValidationError.applicationChanged
        }
    }
}

private struct AutoInsertDiagnosticFixture: CustomTestStringConvertible {
    let error: Error
    let stage: DebugLogStage
    let diagnosticError: DebugLogError

    var testDescription: String {
        "\(stage.rawValue)-\(diagnosticError.rawValue)"
    }
}

@MainActor
private final class DebugErrorLoggerSpy: DebugErrorLogging {
    private(set) var events: [DebugErrorEvent] = []

    func record(_ event: DebugErrorEvent) {
        events.append(event)
    }
}

@MainActor
private final class ClipboardWriterSpy: ClipboardWriting {
    private(set) var values: [String] = []

    func write(_ text: String) throws {
        values.append(text)
    }
}

@MainActor
private final class OutputTargetCoordinatorSpy: AutoInsertTargetCoordinating {
    private let error: Error
    private(set) var clearCount = 0

    init(error: Error) {
        self.error = error
    }

    func revalidateForOutput() throws -> AutoInsertTargetObservation {
        throw error
    }

    func clear() {
        clearCount += 1
    }
}

@MainActor
private final class AutoInsertWriterSpy: AutoInsertWriting {
    private(set) var replacements: [String] = []

    func replaceSelection(
        with replacement: String,
        in target: AutoInsertTargetObservation
    ) async throws -> AutoInsertWriteResult {
        replacements.append(replacement)
        return AutoInsertWriteResult(cursorUpdated: true)
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
