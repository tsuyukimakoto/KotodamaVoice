import CryptoKit
import Foundation

struct LicenseDocument: Identifiable, Equatable {
    let id: String
    let displayName: String
    let licenseName: String
    let licenseFile: String
    let text: String
}

enum LicenseCatalogError: Error, Equatable {
    case missingResource(String)
    case invalidManifest
    case invalidLicenseDocument(String)
}

struct LicenseCatalog {
    let documents: [LicenseDocument]

    init(bundle: Bundle = .main) throws {
        let projectLicense = try Self.readResource(
            named: "LICENSE",
            bundle: bundle
        )
        guard let manifestURL = bundle.url(
            forResource: "ThirdPartyComponents",
            withExtension: "json"
        ) else {
            throw LicenseCatalogError.missingResource(
                "ThirdPartyComponents.json"
            )
        }

        let manifest: BundledThirdPartyManifest
        do {
            manifest = try JSONDecoder().decode(
                BundledThirdPartyManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            throw LicenseCatalogError.invalidManifest
        }
        guard manifest.schemaVersion == 1 else {
            throw LicenseCatalogError.invalidManifest
        }

        var loadedDocuments = [
            LicenseDocument(
                id: "KotodamaVoice",
                displayName: "KotodamaVoice",
                licenseName: "MIT",
                licenseFile: "LICENSE",
                text: projectLicense
            )
        ]
        for component in manifest.components where
            component.scopes.contains("application") {
            let resourceName = (component.licenseFile as NSString)
                .lastPathComponent
            let text = try Self.readResource(
                named: resourceName,
                bundle: bundle
            )
            let digest = SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == component.licenseSHA256 else {
                throw LicenseCatalogError.invalidLicenseDocument(component.id)
            }
            loadedDocuments.append(
                LicenseDocument(
                    id: component.id,
                    displayName: component.displayName,
                    licenseName: component.licenseName,
                    licenseFile: resourceName,
                    text: text
                )
            )
        }
        documents = loadedDocuments
    }

    private static func readResource(
        named name: String,
        bundle: Bundle
    ) throws -> String {
        guard let url = bundle.url(forResource: name, withExtension: nil) else {
            throw LicenseCatalogError.missingResource(name)
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw LicenseCatalogError.invalidLicenseDocument(name)
        }
    }
}

private struct BundledThirdPartyManifest: Decodable {
    let schemaVersion: Int
    let components: [BundledThirdPartyComponent]
}

private struct BundledThirdPartyComponent: Decodable {
    let id: String
    let displayName: String
    let licenseName: String
    let licenseFile: String
    let licenseSHA256: String
    let scopes: [String]
}
