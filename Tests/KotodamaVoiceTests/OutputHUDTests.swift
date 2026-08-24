import AppKit
import Testing
@testable import KotodamaVoice

@Test @MainActor
func outputHUDReusesOnePanelAndReplacesItsPresentation() {
    let presenter = OutputHUDPresenterSpy()
    let scheduler = OutputHUDSchedulerSpy()
    var creationCount = 0
    let controller = OutputHUDController(
        presenterFactory: {
            creationCount += 1
            return presenter
        },
        scheduler: scheduler,
        dismissAfter: 2
    )

    controller.show(.clipboardSucceeded)
    controller.show(.clipboardFailed)

    #expect(creationCount == 1)
    #expect(presenter.presentations.count == 2)
    #expect(presenter.presentations.last?.title == "クリップボードへコピーできませんでした")
}

@Test @MainActor
func outputHUDResetsDismissalAndIgnoresAnObsoleteTimer() {
    let presenter = OutputHUDPresenterSpy()
    let scheduler = OutputHUDSchedulerSpy()
    let controller = OutputHUDController(
        presenterFactory: { presenter },
        scheduler: scheduler,
        dismissAfter: 2
    )

    controller.show(.clipboardSucceeded)
    controller.show(.clipboardFailed)

    #expect(scheduler.scheduled.count == 2)
    #expect(scheduler.scheduled[0].isCancelled)

    scheduler.scheduled[0].fire()
    #expect(presenter.hideCount == 0)

    scheduler.scheduled[1].fire()
    #expect(presenter.hideCount == 1)
}

@Test @MainActor
func outputHUDPresentationContainsOnlyMethodAndOutcome() {
    let presenter = OutputHUDPresenterSpy()
    let controller = OutputHUDController(
        presenterFactory: { presenter },
        scheduler: OutputHUDSchedulerSpy(),
        dismissAfter: 2
    )
    let sensitiveBody = "HUDに表示してはいけない音声入力本文"

    controller.show(.clipboardSucceeded)

    let visibleText = presenter.presentations
        .flatMap { [$0.title, $0.detail] }
        .joined(separator: "\n")
    #expect(!visibleText.contains(sensitiveBody))
    #expect(visibleText.contains("クリップボード"))
    #expect(visibleText.contains("成功"))
}

@Test @MainActor
func outputHUDPanelCannotBecomeKeyOrMain() {
    _ = NSApplication.shared
    let presenter = OutputHUDPanelPresenter()

    presenter.show(OutputHUDNotification.clipboardSucceeded.presentation)

    #expect(presenter.panel.styleMask.contains(.nonactivatingPanel))
    #expect(!presenter.panel.canBecomeKey)
    #expect(!presenter.panel.canBecomeMain)
    #expect(!presenter.panel.isKeyWindow)
    presenter.hide()
}

@Test
func autoInsertSuccessDoesNotRequestAHUDNotification() {
    #expect(OutputDeliveryOutcome.automaticInsertionSucceeded.hudNotification == nil)
    #expect(
        OutputDeliveryOutcome.clipboardSucceeded.hudNotification
            == .clipboardSucceeded
    )
    #expect(
        OutputDeliveryOutcome.automaticInsertionFellBackToClipboard.hudNotification
            == .automaticInsertionFellBackToClipboard
    )
}

@MainActor
private final class OutputHUDPresenterSpy: OutputHUDPresenting {
    private(set) var presentations: [OutputHUDPresentation] = []
    private(set) var hideCount = 0

    func show(_ presentation: OutputHUDPresentation) {
        presentations.append(presentation)
    }

    func hide() {
        hideCount += 1
    }
}

@MainActor
private final class OutputHUDSchedulerSpy: OutputHUDDismissScheduling {
    private(set) var scheduled: [OutputHUDScheduledAction] = []

    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> OutputHUDDismissalCancelling {
        let scheduled = OutputHUDScheduledAction(delay: delay, action: action)
        self.scheduled.append(scheduled)
        return scheduled
    }
}

@MainActor
private final class OutputHUDScheduledAction: OutputHUDDismissalCancelling {
    let delay: TimeInterval
    private let action: @MainActor () -> Void
    private(set) var isCancelled = false

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.delay = delay
        self.action = action
    }

    func cancel() {
        isCancelled = true
    }

    func fire() {
        action()
    }
}
