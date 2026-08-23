import Testing
@testable import KotodamaVoice

@Test @MainActor
func clipboardReplacesAndReadsBackFinalText() throws {
    let pasteboard = PasteboardSpy()
    pasteboard.value = "以前の内容"
    let output = ClipboardOutput(pasteboard: pasteboard)

    try output.write("音声入力の結果")

    #expect(pasteboard.value == "音声入力の結果")
    #expect(pasteboard.replaceCount == 1)
}

@Test @MainActor
func clipboardReportsWriteAndVerificationFailures() {
    let writeFailure = PasteboardSpy()
    writeFailure.acceptsWrites = false
    #expect(throws: ClipboardOutputError.writeFailed) {
        try ClipboardOutput(pasteboard: writeFailure).write("結果")
    }

    let readFailure = PasteboardSpy()
    readFailure.readOverride = "競合した内容"
    #expect(throws: ClipboardOutputError.verificationFailed) {
        try ClipboardOutput(pasteboard: readFailure).write("結果")
    }
}

@MainActor
private final class PasteboardSpy: PasteboardAccessing {
    var value: String?
    var readOverride: String?
    var acceptsWrites = true
    private(set) var replaceCount = 0

    func replaceString(_ value: String) -> Bool {
        replaceCount += 1
        guard acceptsWrites else { return false }
        self.value = value
        return true
    }

    func readString() -> String? {
        readOverride ?? value
    }
}
