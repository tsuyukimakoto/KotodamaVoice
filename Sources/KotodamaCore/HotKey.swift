import Foundation
import Observation

public struct HotKeyDescriptor: Equatable, Sendable {
    public let keyCode: UInt32
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct HotKeyRegistrationToken: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum HotKeyEvent: Equatable, Sendable {
    case pressed
    case released
}

public enum HotKeyRegistrationError: Error, Equatable, Sendable {
    case conflict
    case systemError(Int32)
}

@MainActor
public protocol HotKeyPreferencePersisting: AnyObject {
    func load() -> HotKeyDescriptor?
    func save(_ descriptor: HotKeyDescriptor)
}

@Observable
@MainActor
public final class HotKeySettingsStore {
    public private(set) var descriptor: HotKeyDescriptor
    public private(set) var registrationError: HotKeyRegistrationError?

    private let controller: GlobalHotKeyController
    private let persistence: HotKeyPreferencePersisting

    public init(
        controller: GlobalHotKeyController,
        persistence: HotKeyPreferencePersisting,
        defaultDescriptor: HotKeyDescriptor
    ) {
        self.controller = controller
        self.persistence = persistence
        descriptor = persistence.load() ?? defaultDescriptor
    }

    public func activate() throws {
        do {
            try controller.register(descriptor)
            registrationError = nil
        } catch let error as HotKeyRegistrationError {
            registrationError = error
            throw error
        }
    }

    public func update(to newDescriptor: HotKeyDescriptor) {
        do {
            try controller.register(newDescriptor)
            persistence.save(newDescriptor)
            descriptor = newDescriptor
            registrationError = nil
        } catch let error as HotKeyRegistrationError {
            registrationError = error
        } catch {
            registrationError = .systemError(-1)
        }
    }
}

public struct HotKeyPressGate: Sendable {
    private var isPressed = false

    public init() {}

    public mutating func consume(_ event: HotKeyEvent) -> Bool {
        switch event {
        case .pressed:
            guard !isPressed else {
                return false
            }
            isPressed = true
            return true
        case .released:
            isPressed = false
            return false
        }
    }
}

@MainActor
public protocol HotKeyRegistering: AnyObject {
    var eventHandler: ((HotKeyRegistrationToken, HotKeyEvent) -> Void)? {
        get
        set
    }

    func register(
        _ descriptor: HotKeyDescriptor
    ) throws -> HotKeyRegistrationToken

    func unregister(_ token: HotKeyRegistrationToken)
}

@MainActor
public final class GlobalHotKeyController {
    public private(set) var descriptor: HotKeyDescriptor?
    public var onPress: (() -> Void)?

    private let backend: HotKeyRegistering
    private var registrationToken: HotKeyRegistrationToken?
    private var pressGate = HotKeyPressGate()

    public init(backend: HotKeyRegistering) {
        self.backend = backend
        backend.eventHandler = { [weak self] token, event in
            self?.handle(token: token, event: event)
        }
    }

    public func register(_ newDescriptor: HotKeyDescriptor) throws {
        let newToken = try backend.register(newDescriptor)
        if let registrationToken {
            backend.unregister(registrationToken)
        }
        registrationToken = newToken
        descriptor = newDescriptor
        pressGate = HotKeyPressGate()
    }

    public func unregister() {
        guard let registrationToken else {
            return
        }
        backend.unregister(registrationToken)
        self.registrationToken = nil
        descriptor = nil
        pressGate = HotKeyPressGate()
    }

    private func handle(
        token: HotKeyRegistrationToken,
        event: HotKeyEvent
    ) {
        guard token == registrationToken, pressGate.consume(event) else {
            return
        }
        onPress?()
    }
}
