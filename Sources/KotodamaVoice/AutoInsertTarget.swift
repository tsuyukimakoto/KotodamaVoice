@preconcurrency import ApplicationServices
import AppKit
import Foundation

struct TextSelectionRange: Equatable {
    let location: Int
    let length: Int
}

final class AutoInsertElementReference: Equatable {
    private enum Storage {
        case accessibility(AXUIElement)
        case test(String)
    }

    private let storage: Storage

    init(accessibilityElement: AXUIElement) {
        storage = .accessibility(accessibilityElement)
    }

    init(testID: String) {
        storage = .test(testID)
    }

    var accessibilityElement: AXUIElement? {
        guard case let .accessibility(element) = storage else {
            return nil
        }
        return element
    }

    static func == (
        lhs: AutoInsertElementReference,
        rhs: AutoInsertElementReference
    ) -> Bool {
        switch (lhs.storage, rhs.storage) {
        case let (.accessibility(lhsElement), .accessibility(rhsElement)):
            CFEqual(lhsElement, rhsElement)
        case let (.test(lhsID), .test(rhsID)):
            lhsID == rhsID
        default:
            false
        }
    }
}

struct AutoInsertTargetObservation: Equatable {
    let processID: Int32
    let element: AutoInsertElementReference
    let role: String
    let isEditable: Bool
    let selection: TextSelectionRange
    let bundleIdentifier: String?

    init(
        processID: Int32,
        element: AutoInsertElementReference,
        role: String,
        isEditable: Bool,
        selection: TextSelectionRange,
        bundleIdentifier: String? = nil
    ) {
        self.processID = processID
        self.element = element
        self.role = role
        self.isEditable = isEditable
        self.selection = selection
        self.bundleIdentifier = bundleIdentifier
    }
}

enum AutoInsertTargetObservationError: Error, Equatable {
    case noFrontmostApplication
    case accessibilityError(Int32)
    case invalidAttribute
    case invalidSelectionRange
}

enum AutoInsertTargetValidationError: Error, Equatable {
    case noCapturedTarget
    case applicationChanged
    case elementChanged
    case roleChanged
    case elementNotEditable
    case selectionChanged
}

@MainActor
protocol AutoInsertTargetObserving: AnyObject {
    func observeTarget() throws -> AutoInsertTargetObservation
}

@MainActor
protocol AutoInsertTargetCoordinating: AnyObject {
    func revalidateForOutput() throws -> AutoInsertTargetObservation
    func clear()
}

@MainActor
final class AutoInsertTargetCoordinator: AutoInsertTargetCoordinating {
    private let observer: AutoInsertTargetObserving
    private(set) var capturedTarget: AutoInsertTargetObservation?

    init(observer: AutoInsertTargetObserving = SystemAutoInsertTargetObserver()) {
        self.observer = observer
    }

    func captureForRecording() throws {
        let observation = try observer.observeTarget()
        guard observation.isEditable else {
            capturedTarget = nil
            throw AutoInsertTargetValidationError.elementNotEditable
        }
        capturedTarget = observation
    }

    func revalidateForOutput() throws -> AutoInsertTargetObservation {
        guard let capturedTarget else {
            throw AutoInsertTargetValidationError.noCapturedTarget
        }
        let current = try observer.observeTarget()
        guard current.processID == capturedTarget.processID else {
            throw AutoInsertTargetValidationError.applicationChanged
        }
        guard current.element == capturedTarget.element else {
            throw AutoInsertTargetValidationError.elementChanged
        }
        guard current.role == capturedTarget.role else {
            throw AutoInsertTargetValidationError.roleChanged
        }
        guard current.isEditable else {
            throw AutoInsertTargetValidationError.elementNotEditable
        }
        guard current.selection == capturedTarget.selection else {
            throw AutoInsertTargetValidationError.selectionChanged
        }
        return current
    }

    func clear() {
        capturedTarget = nil
    }
}

@MainActor
final class SystemAutoInsertTargetObserver: AutoInsertTargetObserving {
    func observeTarget() throws -> AutoInsertTargetObservation {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            throw diagnostic(
                AutoInsertTargetObservationError.noFrontmostApplication,
                stage: .focusedApplication
            )
        }

        let processID = application.processIdentifier
        let bundleIdentifier = application.bundleIdentifier
        let applicationElement = AXUIElementCreateApplication(processID)
        let focusedElement: AXUIElement
        do {
            focusedElement = try copyAttribute(
                kAXFocusedUIElementAttribute as CFString,
                from: applicationElement
            )
        } catch {
            throw diagnostic(
                error,
                stage: .focusedElement,
                bundleIdentifier: bundleIdentifier
            )
        }
        let role: String
        do {
            role = try copyAttribute(
                kAXRoleAttribute as CFString,
                from: focusedElement
            )
        } catch {
            throw diagnostic(
                error,
                stage: .role,
                bundleIdentifier: bundleIdentifier
            )
        }
        let selectionValue: AXValue
        do {
            selectionValue = try copyAttribute(
                kAXSelectedTextRangeAttribute as CFString,
                from: focusedElement
            )
        } catch {
            throw diagnostic(
                error,
                stage: .selectedTextRange,
                bundleIdentifier: bundleIdentifier,
                role: role
            )
        }

        var selectionRange = CFRange()
        guard AXValueGetType(selectionValue) == .cfRange,
            AXValueGetValue(selectionValue, .cfRange, &selectionRange)
        else {
            throw diagnostic(
                AutoInsertTargetObservationError.invalidSelectionRange,
                stage: .selectedTextRange,
                bundleIdentifier: bundleIdentifier,
                role: role
            )
        }

        var isSelectionSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &isSelectionSettable
        )
        guard settableError == .success else {
            throw diagnostic(
                AutoInsertTargetObservationError.accessibilityError(
                    settableError.rawValue
                ),
                stage: .selectionSettable,
                bundleIdentifier: bundleIdentifier,
                role: role
            )
        }

        return AutoInsertTargetObservation(
            processID: processID,
            element: AutoInsertElementReference(accessibilityElement: focusedElement),
            role: role,
            isEditable: isSelectionSettable.boolValue,
            selection: TextSelectionRange(
                location: selectionRange.location,
                length: selectionRange.length
            ),
            bundleIdentifier: bundleIdentifier
        )
    }

    private func diagnostic(
        _ error: Error,
        stage: DebugLogStage,
        bundleIdentifier: String? = nil,
        role: String? = nil
    ) -> AutoInsertDiagnosticError {
        let event = autoInsertDebugEvent(for: error, defaultStage: stage)
        return AutoInsertDiagnosticError(
            event: DebugErrorEvent(
                area: event.area,
                stage: stage,
                error: event.error,
                code: event.code,
                bundleIdentifier: bundleIdentifier,
                role: role
            ),
            underlyingError: error
        )
    }

    private func copyAttribute<Value>(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> Value {
        var rawValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &rawValue)
        guard error == .success else {
            throw AutoInsertTargetObservationError.accessibilityError(error.rawValue)
        }
        guard let value = rawValue as? Value else {
            throw AutoInsertTargetObservationError.invalidAttribute
        }
        return value
    }
}
