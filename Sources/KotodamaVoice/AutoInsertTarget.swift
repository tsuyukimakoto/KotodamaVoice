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
            throw AutoInsertTargetObservationError.noFrontmostApplication
        }

        let processID = application.processIdentifier
        let applicationElement = AXUIElementCreateApplication(processID)
        let focusedElement: AXUIElement = try copyAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: applicationElement
        )
        let role: String = try copyAttribute(
            kAXRoleAttribute as CFString,
            from: focusedElement
        )
        let selectionValue: AXValue = try copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: focusedElement
        )

        var selectionRange = CFRange()
        guard AXValueGetType(selectionValue) == .cfRange,
            AXValueGetValue(selectionValue, .cfRange, &selectionRange)
        else {
            throw AutoInsertTargetObservationError.invalidSelectionRange
        }

        var isSelectionSettable = DarwinBoolean(false)
        let settableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &isSelectionSettable
        )
        guard settableError == .success else {
            throw AutoInsertTargetObservationError.accessibilityError(
                settableError.rawValue
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
            )
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
