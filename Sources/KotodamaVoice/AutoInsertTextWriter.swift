@preconcurrency import ApplicationServices
import AppKit
import Foundation

struct AutoInsertWriteResult: Equatable {
    let cursorUpdated: Bool
}

enum AutoInsertTextWriterError: Error, Equatable {
    case missingAccessibilityElement
    case accessibilityError(Int32)
    case invalidAttribute
    case invalidSelectionRange
    case selectionChanged
    case rangeOutOfBounds
    case pasteboardWriteFailed
    case pasteActionUnavailable
    case targetNoLongerFrontmost
    case focusedElementChanged
    case verificationFailed
}

@MainActor
protocol AutoInsertTextAccessing: AnyObject {
    func readValue(from element: AutoInsertElementReference) throws -> String
    func readSelection(
        from element: AutoInsertElementReference
    ) throws -> TextSelectionRange
    func paste(
        _ replacement: String,
        into target: AutoInsertTargetObservation
    ) throws
}

@MainActor
protocol AutoInsertWriting: AnyObject {
    @discardableResult
    func replaceSelection(
        with replacement: String,
        in target: AutoInsertTargetObservation
    ) async throws -> AutoInsertWriteResult
}

@MainActor
final class AutoInsertTextWriter: AutoInsertWriting {
    private let access: AutoInsertTextAccessing

    init(access: AutoInsertTextAccessing = SystemAutoInsertTextAccess()) {
        self.access = access
    }

    @discardableResult
    func replaceSelection(
        with replacement: String,
        in target: AutoInsertTargetObservation
    ) async throws -> AutoInsertWriteResult {
        let currentSelection = try access.readSelection(from: target.element)
        guard currentSelection == target.selection else {
            throw AutoInsertTextWriterError.selectionChanged
        }

        let original = try access.readValue(from: target.element)
        let originalUTF16 = original as NSString
        let range = NSRange(
            location: currentSelection.location,
            length: currentSelection.length
        )
        guard range.location >= 0,
            range.length >= 0,
            range.location <= originalUTF16.length,
            range.length <= originalUTF16.length - range.location
        else {
            throw AutoInsertTextWriterError.rangeOutOfBounds
        }

        let updated = originalUTF16.replacingCharacters(
            in: range,
            with: replacement
        )
        try access.paste(replacement, into: target)

        for attempt in 0..<10 {
            if try access.readValue(from: target.element) == updated {
                let expectedCursor = TextSelectionRange(
                    location: range.location + (replacement as NSString).length,
                    length: 0
                )
                let cursor = try? access.readSelection(from: target.element)
                return AutoInsertWriteResult(cursorUpdated: cursor == expectedCursor)
            }
            if attempt < 9 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        throw AutoInsertTextWriterError.verificationFailed
    }
}

@MainActor
protocol AutoInsertPasteCommandPerforming: AnyObject {
    func performPaste(into target: AutoInsertTargetObservation) throws
}

@MainActor
final class SystemAutoInsertTextAccess: AutoInsertTextAccessing {
    private let clipboard: ClipboardOutput
    private let pasteCommand: AutoInsertPasteCommandPerforming

    init(
        clipboard: ClipboardOutput = ClipboardOutput(),
        pasteCommand: AutoInsertPasteCommandPerforming = SystemPasteMenuCommand()
    ) {
        self.clipboard = clipboard
        self.pasteCommand = pasteCommand
    }

    func readValue(from element: AutoInsertElementReference) throws -> String {
        try copyAttribute(kAXValueAttribute as CFString, from: requiredElement(element))
    }

    func readSelection(
        from element: AutoInsertElementReference
    ) throws -> TextSelectionRange {
        let selectionValue: AXValue = try copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: requiredElement(element)
        )
        var range = CFRange()
        guard AXValueGetType(selectionValue) == .cfRange,
            AXValueGetValue(selectionValue, .cfRange, &range)
        else {
            throw AutoInsertTextWriterError.invalidSelectionRange
        }
        return TextSelectionRange(location: range.location, length: range.length)
    }

    func paste(
        _ replacement: String,
        into target: AutoInsertTargetObservation
    ) throws {
        do {
            try clipboard.write(replacement)
        } catch {
            throw AutoInsertTextWriterError.pasteboardWriteFailed
        }
        try pasteCommand.performPaste(into: target)
    }

    private func requiredElement(
        _ reference: AutoInsertElementReference
    ) throws -> AXUIElement {
        guard let element = reference.accessibilityElement else {
            throw AutoInsertTextWriterError.missingAccessibilityElement
        }
        return element
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> Value {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard error == .success else {
            throw AutoInsertTextWriterError.accessibilityError(error.rawValue)
        }
        guard let value = rawValue as? Value else {
            throw AutoInsertTextWriterError.invalidAttribute
        }
        return value
    }
}

@MainActor
final class SystemPasteMenuCommand: AutoInsertPasteCommandPerforming {
    func performPaste(into target: AutoInsertTargetObservation) throws {
        let application = try validateCurrentTarget(target)
        let menuBar: AXUIElement = try copyAttribute(
            kAXMenuBarAttribute as CFString,
            from: application
        )
        guard let pasteItem = try findOrRevealPasteItem(
            in: menuBar,
            target: target
        ) else {
            throw AutoInsertTextWriterError.pasteActionUnavailable
        }
        _ = try validateCurrentTarget(target)
        let error = AXUIElementPerformAction(
            pasteItem,
            kAXPressAction as CFString
        )
        guard error == .success else {
            throw AutoInsertTextWriterError.accessibilityError(error.rawValue)
        }
    }

    private func findOrRevealPasteItem(
        in menuBar: AXUIElement,
        target: AutoInsertTargetObservation
    ) throws -> AXUIElement? {
        if let pasteItem = findPasteItem(in: menuBar) {
            return pasteItem
        }

        let menuBarItems: [AXUIElement] = optionalAttribute(
            kAXChildrenAttribute as CFString,
            from: menuBar
        ) ?? []
        for menuBarItem in menuBarItems where role(of: menuBarItem) == kAXMenuBarItemRole as String {
            _ = try validateCurrentTarget(target)
            guard showMenu(menuBarItem) else {
                continue
            }
            if let pasteItem = findPasteItem(in: menuBarItem) {
                return pasteItem
            }
            _ = AXUIElementPerformAction(
                menuBarItem,
                kAXCancelAction as CFString
            )
        }
        return nil
    }

    private func showMenu(_ menuBarItem: AXUIElement) -> Bool {
        let showError = AXUIElementPerformAction(
            menuBarItem,
            kAXShowMenuAction as CFString
        )
        if showError == .success {
            return true
        }
        return AXUIElementPerformAction(
            menuBarItem,
            kAXPressAction as CFString
        ) == .success
    }

    private func role(of element: AXUIElement) -> String? {
        optionalAttribute(kAXRoleAttribute as CFString, from: element)
    }

    private func validateCurrentTarget(
        _ target: AutoInsertTargetObservation
    ) throws -> AXUIElement {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
            == target.processID
        else {
            throw AutoInsertTextWriterError.targetNoLongerFrontmost
        }
        let application = AXUIElementCreateApplication(target.processID)
        let focusedElement: AXUIElement = try copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        )
        guard let expectedElement = target.element.accessibilityElement,
            CFEqual(focusedElement, expectedElement)
        else {
            throw AutoInsertTextWriterError.focusedElementChanged
        }
        let selectionValue: AXValue = try copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: focusedElement
        )
        var selection = CFRange()
        guard AXValueGetType(selectionValue) == .cfRange,
            AXValueGetValue(selectionValue, .cfRange, &selection)
        else {
            throw AutoInsertTextWriterError.invalidSelectionRange
        }
        guard selection.location == target.selection.location,
            selection.length == target.selection.length
        else {
            throw AutoInsertTextWriterError.selectionChanged
        }
        return application
    }

    private func findPasteItem(in root: AXUIElement) -> AXUIElement? {
        var pending = [root]
        var inspectedCount = 0
        while let element = pending.popLast(), inspectedCount < 2_000 {
            inspectedCount += 1
            if isStandardPasteItem(element) {
                return element
            }
            let children: [AXUIElement] = optionalAttribute(
                kAXChildrenAttribute as CFString,
                from: element
            ) ?? []
            pending.append(contentsOf: children.reversed())
        }
        return nil
    }

    private func isStandardPasteItem(_ element: AXUIElement) -> Bool {
        let role: String? = optionalAttribute(
            kAXRoleAttribute as CFString,
            from: element
        )
        guard role == kAXMenuItemRole as String else {
            return false
        }
        let commandCharacter: String? = optionalAttribute(
            kAXMenuItemCmdCharAttribute as CFString,
            from: element
        )
        guard commandCharacter?.lowercased() == "v" else {
            return false
        }
        let modifiers: NSNumber? = optionalAttribute(
            kAXMenuItemCmdModifiersAttribute as CFString,
            from: element
        )
        // AX defines zero as no modifiers other than the implicit Command key.
        guard modifiers?.uint32Value == 0 else {
            return false
        }
        let enabled: NSNumber? = optionalAttribute(
            kAXEnabledAttribute as CFString,
            from: element
        )
        return enabled?.boolValue != false
    }

    private func optionalAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> Value? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &rawValue) == .success
        else {
            return nil
        }
        return rawValue as? Value
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> Value {
        guard let value: Value = optionalAttribute(attribute, from: element) else {
            throw AutoInsertTextWriterError.pasteActionUnavailable
        }
        return value
    }
}
