import AppKit
import Foundation

struct OutputHUDPresentation: Equatable {
    let title: String
    let detail: String
    let symbolName: String
}

enum OutputHUDNotification {
    case clipboardSucceeded
    case clipboardSucceededWithFormattingFallback
    case clipboardFailed
    case automaticInsertionSucceeded
    case automaticInsertionFellBackToClipboard
    case automaticInsertionFailed

    var presentation: OutputHUDPresentation {
        switch self {
        case .clipboardSucceeded:
            OutputHUDPresentation(
                title: "クリップボードへコピーしました",
                detail: "成功",
                symbolName: "checkmark.circle.fill"
            )
        case .clipboardSucceededWithFormattingFallback:
            OutputHUDPresentation(
                title: "原文をクリップボードへコピーしました",
                detail: "整形を適用できませんでした",
                symbolName: "exclamationmark.circle.fill"
            )
        case .clipboardFailed:
            OutputHUDPresentation(
                title: "クリップボードへコピーできませんでした",
                detail: "失敗",
                symbolName: "xmark.circle.fill"
            )
        case .automaticInsertionSucceeded:
            OutputHUDPresentation(
                title: "入力先へ挿入しました",
                detail: "成功",
                symbolName: "checkmark.circle.fill"
            )
        case .automaticInsertionFellBackToClipboard:
            OutputHUDPresentation(
                title: "クリップボードへコピーしました",
                detail: "自動挿入を利用できませんでした",
                symbolName: "exclamationmark.circle.fill"
            )
        case .automaticInsertionFailed:
            OutputHUDPresentation(
                title: "入力先へ挿入できませんでした",
                detail: "失敗",
                symbolName: "xmark.circle.fill"
            )
        }
    }
}

@MainActor
protocol OutputHUDPresenting: AnyObject {
    func show(_ presentation: OutputHUDPresentation)
    func hide()
}

@MainActor
protocol OutputHUDDismissalCancelling: AnyObject {
    func cancel()
}

@MainActor
protocol OutputHUDDismissScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> OutputHUDDismissalCancelling
}

@MainActor
final class OutputHUDController {
    private let presenterFactory: @MainActor () -> OutputHUDPresenting
    private let scheduler: OutputHUDDismissScheduling
    private let dismissAfter: TimeInterval
    private var presenter: OutputHUDPresenting?
    private var scheduledDismissal: OutputHUDDismissalCancelling?
    private var presentationGeneration = 0

    init(
        presenterFactory: @escaping @MainActor () -> OutputHUDPresenting = {
            OutputHUDPanelPresenter()
        },
        scheduler: OutputHUDDismissScheduling = OutputHUDTimerScheduler(),
        dismissAfter: TimeInterval = 2
    ) {
        self.presenterFactory = presenterFactory
        self.scheduler = scheduler
        self.dismissAfter = dismissAfter
    }

    func show(_ notification: OutputHUDNotification) {
        presentationGeneration += 1
        let generation = presentationGeneration
        scheduledDismissal?.cancel()

        let presenter = presenter ?? presenterFactory()
        self.presenter = presenter
        presenter.show(notification.presentation)

        scheduledDismissal = scheduler.schedule(after: dismissAfter) { [weak self] in
            guard let self, self.presentationGeneration == generation else {
                return
            }
            self.presenter?.hide()
            self.scheduledDismissal = nil
        }
    }
}

@MainActor
final class OutputHUDPanelPresenter: OutputHUDPresenting {
    let panel: NSPanel

    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()

    init() {
        panel = NonactivatingOutputHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        configurePanel()
        configureContent()
    }

    func show(_ presentation: OutputHUDPresentation) {
        titleLabel.stringValue = presentation.title
        detailLabel.stringValue = presentation.detail
        symbolView.image = NSImage(
            systemSymbolName: presentation.symbolName,
            accessibilityDescription: nil
        )
        positionOnCurrentScreen()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.identifier = NSUserInterfaceItemIdentifier("output-hud")
    }

    private func configureContent() {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        symbolView.contentTintColor = .controlAccentColor

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.identifier = NSUserInterfaceItemIdentifier("output-hud-title")

        detailLabel.font = .systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.identifier = NSUserInterfaceItemIdentifier("output-hud-detail")

        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 4
        labels.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(symbolView)
        background.addSubview(labels)
        panel.contentView = background

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            symbolView.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 34),
            symbolView.heightAnchor.constraint(equalToConstant: 34),
            labels.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 14),
            labels.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            labels.centerYAnchor.constraint(equalTo: background.centerYAnchor),
        ])
    }

    private func positionOnCurrentScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            return
        }

        let panelFrame = panel.frame
        panel.setFrameOrigin(
            NSPoint(
                x: visibleFrame.midX - panelFrame.width / 2,
                y: visibleFrame.maxY - panelFrame.height - 48
            )
        )
    }
}

private final class NonactivatingOutputHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class OutputHUDTimerScheduler: OutputHUDDismissScheduling {
    func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor () -> Void
    ) -> OutputHUDDismissalCancelling {
        OutputHUDTimerDismissal(delay: delay, action: action)
    }
}

@MainActor
private final class OutputHUDTimerDismissal: NSObject, OutputHUDDismissalCancelling {
    private var timer: Timer?
    private var action: (@MainActor () -> Void)?

    init(delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        self.action = action
        super.init()
        timer = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(fire),
            userInfo: nil,
            repeats: false
        )
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        action = nil
    }

    @objc private func fire() {
        timer = nil
        let action = action
        self.action = nil
        action?()
    }
}
