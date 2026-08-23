import Carbon.HIToolbox
import KotodamaCore

@MainActor
final class CarbonHotKeyBackend: HotKeyRegistering {
    var eventHandler: ((HotKeyRegistrationToken, HotKeyEvent) -> Void)?

    private static let signature: OSType = 0x4B_56_48_4B

    private struct Registration {
        let token: HotKeyRegistrationToken
        let reference: EventHotKeyRef
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextIdentifier: UInt32 = 1
    private var installedEventHandler: EventHandlerRef?

    init() throws {
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                let backend = Unmanaged<CarbonHotKeyBackend>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                return MainActor.assumeIsolated {
                    backend.handle(event)
                }
            },
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &installedEventHandler
        )

        guard status == noErr else {
            throw HotKeyRegistrationError.systemError(status)
        }
    }

    func register(
        _ descriptor: HotKeyDescriptor
    ) throws -> HotKeyRegistrationToken {
        let identifier = nextIdentifier
        nextIdentifier &+= 1

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: identifier
        )
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            descriptor.keyCode,
            descriptor.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr {
                throw HotKeyRegistrationError.conflict
            }
            throw HotKeyRegistrationError.systemError(status)
        }

        let token = HotKeyRegistrationToken()
        registrations[identifier] = Registration(
            token: token,
            reference: reference
        )
        return token
    }

    func unregister(_ token: HotKeyRegistrationToken) {
        guard let entry = registrations.first(where: {
            $0.value.token == token
        }) else {
            return
        }
        UnregisterEventHotKey(entry.value.reference)
        registrations.removeValue(forKey: entry.key)
    }

    func shutdown() {
        for registration in registrations.values {
            UnregisterEventHotKey(registration.reference)
        }
        registrations.removeAll()

        if let installedEventHandler {
            RemoveEventHandler(installedEventHandler)
            self.installedEventHandler = nil
        }
    }

    private func handle(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID(signature: 0, id: 0)
        let parameterStatus = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard parameterStatus == noErr,
              hotKeyID.signature == Self.signature,
              let registration = registrations[hotKeyID.id]
        else {
            return OSStatus(eventNotHandledErr)
        }

        let eventKind: HotKeyEvent
        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            eventKind = .pressed
        case UInt32(kEventHotKeyReleased):
            eventKind = .released
        default:
            return OSStatus(eventNotHandledErr)
        }

        eventHandler?(registration.token, eventKind)
        return noErr
    }
}
