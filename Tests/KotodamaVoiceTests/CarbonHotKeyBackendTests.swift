import Carbon.HIToolbox
import Testing
@testable import KotodamaVoice

@Test @MainActor
func carbonHotKeyRegistrationIsExclusiveAcrossApplications() {
    #expect(
        CarbonHotKeyBackend.registrationOptions
            == OptionBits(kEventHotKeyExclusive)
    )
}
