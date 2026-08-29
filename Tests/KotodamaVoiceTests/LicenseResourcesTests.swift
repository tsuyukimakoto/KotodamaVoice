import Foundation
import Testing
@testable import KotodamaVoice

@Test func distributedLicenseResourcesAreBundled() {
    let expectedResources = [
        "LICENSE",
        "THIRD_PARTY_NOTICES.md",
        "ThirdPartyComponents.json",
        "whisper.cpp-LICENSE.txt",
        "llama.cpp-LICENSE.txt",
        "OpenAI-Whisper-LICENSE.txt",
        "Apache-2.0.txt",
    ]

    for resource in expectedResources {
        #expect(
            Bundle.main.url(forResource: resource, withExtension: nil) != nil,
            "Bundle resource is missing: \(resource)"
        )
    }
}

@Test func licenseCatalogLoadsBundledDocumentsOffline() throws {
    let catalog = try LicenseCatalog(bundle: .main)

    #expect(catalog.documents.first?.displayName == "KotodamaVoice")
    #expect(catalog.documents.contains { document in
        document.displayName == "whisper.cpp"
            && document.text.contains("MIT License")
    })
    #expect(catalog.documents.contains { document in
        document.displayName == "Gemma 4 E4B IT QAT Q4_0 model"
            && document.text.contains("Apache License")
    })
}
