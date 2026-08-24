import Testing
@testable import KotodamaVoice

@Test @MainActor
func autoInsertTargetRevalidatesAnUnchangedRecordingTarget() throws {
    let target = autoInsertObservation()
    let observer = AutoInsertTargetObserverSpy(observations: [target, target])
    let coordinator = AutoInsertTargetCoordinator(observer: observer)

    try coordinator.captureForRecording()
    let validated = try coordinator.revalidateForOutput()

    #expect(validated == target)
}

@Test @MainActor
func autoInsertTargetRejectsAFrontmostApplicationChange() throws {
    let captured = autoInsertObservation(processID: 100)
    let current = autoInsertObservation(processID: 200)
    let coordinator = AutoInsertTargetCoordinator(
        observer: AutoInsertTargetObserverSpy(observations: [captured, current])
    )
    try coordinator.captureForRecording()

    #expect(throws: AutoInsertTargetValidationError.applicationChanged) {
        try coordinator.revalidateForOutput()
    }
}

@Test @MainActor
func autoInsertTargetRejectsAnInvalidatedOrReplacedElement() throws {
    let captured = autoInsertObservation(elementID: "original")
    let current = autoInsertObservation(elementID: "replacement")
    let coordinator = AutoInsertTargetCoordinator(
        observer: AutoInsertTargetObserverSpy(observations: [captured, current])
    )
    try coordinator.captureForRecording()

    #expect(throws: AutoInsertTargetValidationError.elementChanged) {
        try coordinator.revalidateForOutput()
    }
}

@Test @MainActor
func autoInsertTargetReportsAnElementThatBecomesInvalid() throws {
    let captured = autoInsertObservation()
    let observer = InvalidatingAutoInsertTargetObserver(firstObservation: captured)
    let coordinator = AutoInsertTargetCoordinator(observer: observer)
    try coordinator.captureForRecording()

    #expect(
        throws: AutoInsertTargetObservationError.accessibilityError(-25_202)
    ) {
        try coordinator.revalidateForOutput()
    }
}

@Test @MainActor
func autoInsertTargetRejectsASelectionChange() throws {
    let captured = autoInsertObservation(selection: TextSelectionRange(location: 4, length: 2))
    let current = autoInsertObservation(selection: TextSelectionRange(location: 6, length: 0))
    let coordinator = AutoInsertTargetCoordinator(
        observer: AutoInsertTargetObserverSpy(observations: [captured, current])
    )
    try coordinator.captureForRecording()

    #expect(throws: AutoInsertTargetValidationError.selectionChanged) {
        try coordinator.revalidateForOutput()
    }
}

@Test @MainActor
func autoInsertTargetRechecksRoleAndEditability() throws {
    let captured = autoInsertObservation(role: "AXTextArea", isEditable: true)
    let changedRole = autoInsertObservation(role: "AXGroup", isEditable: true)
    let roleCoordinator = AutoInsertTargetCoordinator(
        observer: AutoInsertTargetObserverSpy(observations: [captured, changedRole])
    )
    try roleCoordinator.captureForRecording()
    #expect(throws: AutoInsertTargetValidationError.roleChanged) {
        try roleCoordinator.revalidateForOutput()
    }

    let notEditable = autoInsertObservation(role: "AXTextArea", isEditable: false)
    let editabilityCoordinator = AutoInsertTargetCoordinator(
        observer: AutoInsertTargetObserverSpy(observations: [captured, notEditable])
    )
    try editabilityCoordinator.captureForRecording()
    #expect(throws: AutoInsertTargetValidationError.elementNotEditable) {
        try editabilityCoordinator.revalidateForOutput()
    }
}

@MainActor
private final class AutoInsertTargetObserverSpy: AutoInsertTargetObserving {
    private var observations: [AutoInsertTargetObservation]

    init(observations: [AutoInsertTargetObservation]) {
        self.observations = observations
    }

    func observeTarget() throws -> AutoInsertTargetObservation {
        observations.removeFirst()
    }
}

@MainActor
private final class InvalidatingAutoInsertTargetObserver: AutoInsertTargetObserving {
    private let firstObservation: AutoInsertTargetObservation
    private var callCount = 0

    init(firstObservation: AutoInsertTargetObservation) {
        self.firstObservation = firstObservation
    }

    func observeTarget() throws -> AutoInsertTargetObservation {
        defer { callCount += 1 }
        if callCount == 0 {
            return firstObservation
        }
        throw AutoInsertTargetObservationError.accessibilityError(-25_202)
    }
}

private func autoInsertObservation(
    processID: Int32 = 100,
    elementID: String = "element",
    role: String = "AXTextArea",
    isEditable: Bool = true,
    selection: TextSelectionRange = TextSelectionRange(location: 4, length: 2)
) -> AutoInsertTargetObservation {
    AutoInsertTargetObservation(
        processID: processID,
        element: AutoInsertElementReference(testID: elementID),
        role: role,
        isEditable: isEditable,
        selection: selection
    )
}
