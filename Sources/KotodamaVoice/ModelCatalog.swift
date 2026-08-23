import Foundation
import KotodamaCore

struct ModelCatalog {
    let models: [ModelManifestEntry]
    let loadError: String?

    init(bundle: Bundle = .main) {
        do {
            guard let url = bundle.url(
                forResource: "Models",
                withExtension: "json"
            ) else {
                throw ModelCatalogError.missingResource
            }
            let manifest = try ModelManifestLoader.decode(Data(contentsOf: url))
            models = manifest.models
            loadError = nil
        } catch {
            models = []
            loadError = "モデルManifestを読み込めませんでした"
        }
    }
}

private enum ModelCatalogError: Error {
    case missingResource
}
