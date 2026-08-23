import Foundation

public enum ModelPurpose: String, Codable, Hashable, Sendable {
    case speech
    case formatter
}

public enum ModelRuntime: String, Codable, Sendable {
    case whisper
    case llama
}

public struct ModelManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let models: [ModelManifestEntry]
}

public struct ModelManifestEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let purpose: ModelPurpose
    public let version: String
    public let sourceURL: URL
    public let revision: String
    public let fileName: String
    public let byteCount: Int64
    public let sha256: String
    public let licenseName: String
    public let licenseURL: URL
    public let runtime: ModelRuntime
    public let isDefault: Bool

    public init(
        id: String,
        displayName: String,
        purpose: ModelPurpose,
        version: String,
        sourceURL: URL,
        revision: String,
        fileName: String,
        byteCount: Int64,
        sha256: String,
        licenseName: String,
        licenseURL: URL,
        runtime: ModelRuntime,
        isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.purpose = purpose
        self.version = version
        self.sourceURL = sourceURL
        self.revision = revision
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
        self.licenseName = licenseName
        self.licenseURL = licenseURL
        self.runtime = runtime
        self.isDefault = isDefault
    }
}

public enum ModelManifestError: Error, Equatable, Sendable {
    case decoding
    case unsupportedSchemaVersion(Int)
    case duplicateID(String)
    case duplicateFileName(String)
    case invalidIdentifier(String)
    case invalidDisplayName(String)
    case invalidVersion(String)
    case invalidSourceURL(String)
    case unpinnedRevision(String)
    case invalidFileName(String)
    case disallowedFileType(String)
    case invalidByteCount(String)
    case invalidSHA256(String)
    case invalidLicense(String)
    case incompatibleRuntime(String)
    case multipleDefaults(ModelPurpose)
}

public enum ModelManifestLoader {
    public static func decode(_ data: Data) throws -> ModelManifest {
        let manifest: ModelManifest
        do {
            manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        } catch {
            throw ModelManifestError.decoding
        }
        try validate(manifest)
        return manifest
    }

    private static func validate(_ manifest: ModelManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ModelManifestError.unsupportedSchemaVersion(
                manifest.schemaVersion
            )
        }

        var identifiers = Set<String>()
        var fileNames = Set<String>()
        var defaultPurposes = Set<ModelPurpose>()
        for model in manifest.models {
            guard identifiers.insert(model.id).inserted else {
                throw ModelManifestError.duplicateID(model.id)
            }
            guard fileNames.insert(model.fileName).inserted else {
                throw ModelManifestError.duplicateFileName(model.fileName)
            }
            if model.isDefault,
               !defaultPurposes.insert(model.purpose).inserted {
                throw ModelManifestError.multipleDefaults(model.purpose)
            }
            try validate(model)
        }
    }

    private static func validate(_ model: ModelManifestEntry) throws {
        let identifierPattern = /^[a-z0-9][a-z0-9._-]*$/
        guard model.id.wholeMatch(of: identifierPattern) != nil else {
            throw ModelManifestError.invalidIdentifier(model.id)
        }
        guard !model.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw ModelManifestError.invalidDisplayName(model.id)
        }
        guard !model.version.isEmpty else {
            throw ModelManifestError.invalidVersion(model.id)
        }
        guard isHTTPSURL(model.sourceURL) else {
            throw ModelManifestError.invalidSourceURL(model.id)
        }

        let revisionPattern = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/
        guard model.revision.wholeMatch(of: revisionPattern) != nil else {
            throw ModelManifestError.unpinnedRevision(model.id)
        }

        let normalizedFileName = (model.fileName as NSString).lastPathComponent
        guard normalizedFileName == model.fileName,
              !model.fileName.hasPrefix("."),
              !model.fileName.isEmpty
        else {
            throw ModelManifestError.invalidFileName(model.fileName)
        }
        let fileExtension = (model.fileName as NSString)
            .pathExtension
            .lowercased()
        guard ["bin", "gguf"].contains(fileExtension) else {
            throw ModelManifestError.disallowedFileType(model.fileName)
        }
        guard model.byteCount > 0 else {
            throw ModelManifestError.invalidByteCount(model.id)
        }
        let shaPattern = /^[0-9a-f]{64}$/
        guard model.sha256.wholeMatch(of: shaPattern) != nil else {
            throw ModelManifestError.invalidSHA256(model.id)
        }
        guard !model.licenseName.isEmpty,
              isHTTPSURL(model.licenseURL)
        else {
            throw ModelManifestError.invalidLicense(model.id)
        }

        let compatible = switch (model.purpose, model.runtime, fileExtension) {
        case (.speech, .whisper, "bin"),
             (.formatter, .llama, "gguf"):
            true
        default:
            false
        }
        guard compatible else {
            throw ModelManifestError.incompatibleRuntime(model.id)
        }
    }

    private static func isHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil
    }
}
