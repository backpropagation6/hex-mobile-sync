import Foundation

/// A Whisper model found on the device, with its tokenizer.
public struct WhisperInstallation: Sendable, Equatable {
    /// The folder with `AudioEncoder.mlmodelc`, `MelSpectrogram.mlmodelc` and
    /// `TextDecoder.mlmodelc`.
    public var modelFolder: URL
    /// The folder with `tokenizer.json` and `tokenizer_config.json` of
    /// `openai/whisper-large-v3`. WhisperKit searches the top level of the
    /// `tokenizerFolder` it is given, so any location works.
    public var tokenizerFolder: URL

    public var modelName: String { modelFolder.lastPathComponent }
}

/// Why Whisper cannot be used on this device.
public enum WhisperMissing: Sendable, Equatable {
    /// `Application Support/whisper` does not exist.
    case noFolder
    /// The folder is there but holds no model.
    case noModel
    /// A model folder lacks some of the Core ML models.
    case incompleteModel(name: String, missing: [String])
    /// The model is not of the supported family (large-v3): its tokenizer
    /// would be searched for, and downloaded, by the library.
    case unsupportedModel(name: String)
    /// The tokenizer files are not there (or not all of them).
    case noTokenizer(missing: [String])

    /// Stable text for the log (`missing=no-model`).
    public var logValue: String {
        switch self {
        case .noFolder: "no-folder"
        case .noModel: "no-model"
        case let .incompleteModel(name, missing): "incomplete-model:\(name):\(missing.joined(separator: "+"))"
        case let .unsupportedModel(name): "unsupported-model:\(name)"
        case let .noTokenizer(missing): "no-tokenizer:\(missing.joined(separator: "+"))"
        }
    }
}

public enum WhisperAvailability: Sendable, Equatable {
    case ready(WhisperInstallation)
    case missing(WhisperMissing)

    public var installation: WhisperInstallation? {
        if case let .ready(installation) = self { installation } else { nil }
    }
}

/// Where the app looks for the Whisper model, and what it must find there.
///
/// The app has no network code for it: the model is copied into the app's
/// container from the Mac (`make push-whisper-model`). The check is strict on
/// purpose. WhisperKit falls back to downloading the tokenizer from the Hugging
/// Face Hub when it does not find one locally, and the app promises not to use
/// the network, so a layout that would trigger that is reported as missing.
///
/// The search is tolerant about *where* things landed, because how
/// `devicectl device copy to` places a copied folder (inside the destination
/// or as the destination) was not proven when this was written: the model may
/// be up to two folders below the root, the tokenizer up to five.
public enum WhisperLocator {
    public static let rootName = "whisper"
    /// What a model folder must contain.
    public static let requiredModels = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"]
    /// The tokenizer folder of the large-v3 family (the turbo model included):
    /// the last component of the Hugging Face repository `openai/whisper-large-v3`.
    public static let tokenizerFolderName = "whisper-large-v3"
    /// What the tokenizer folder must contain.
    public static let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]
    /// The supported model family, by folder name (`openai_whisper-large-v3-v20240930_turbo_632MB`).
    public static let supportedFamily = "large-v3"

    private static let maxModelDepth = 2
    private static let maxTokenizerDepth = 5

    public static func locate(root: URL, fileManager: FileManager = .default) -> WhisperAvailability {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing(.noFolder)
        }

        var partial: (name: String, missing: [String])?
        var unsupported: String?
        var model: URL?
        for candidate in folders(under: root, maxDepth: maxModelDepth, fileManager: fileManager) {
            let missing = requiredModels.filter { !fileManager.fileExists(atPath: candidate.appending(path: $0).path) }
            if missing.count == requiredModels.count { continue }
            if !missing.isEmpty {
                if partial == nil { partial = (candidate.lastPathComponent, missing) }
                continue
            }
            guard candidate.lastPathComponent.contains(supportedFamily) else {
                if unsupported == nil { unsupported = candidate.lastPathComponent }
                continue
            }
            model = candidate
            break
        }
        guard let model else {
            if let unsupported { return .missing(.unsupportedModel(name: unsupported)) }
            if let partial { return .missing(.incompleteModel(name: partial.name, missing: partial.missing)) }
            return .missing(.noModel)
        }

        var closest: [String]?
        for candidate in folders(under: root, maxDepth: maxTokenizerDepth, fileManager: fileManager)
        where candidate.lastPathComponent == tokenizerFolderName {
            let absent = requiredTokenizerFiles.filter { !fileManager.fileExists(atPath: candidate.appending(path: $0).path) }
            if absent.isEmpty { return .ready(WhisperInstallation(modelFolder: model, tokenizerFolder: candidate)) }
            if closest == nil { closest = absent }
        }
        return .missing(.noTokenizer(missing: closest ?? requiredTokenizerFiles))
    }

    /// `root` and its subfolders down to `maxDepth`, shallowest first and in
    /// name order within a level. Hidden folders, Core ML model bundles and
    /// everything inside them are left out.
    static func folders(under root: URL, maxDepth: Int, fileManager: FileManager) -> [URL] {
        var result = [root]
        var level = [root]
        for _ in 0..<maxDepth {
            var next: [URL] = []
            for folder in level {
                let entries = (try? fileManager.contentsOfDirectory(
                    at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                next += entries
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .filter { $0.pathExtension != "mlmodelc" }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            if next.isEmpty { break }
            result += next
            level = next
        }
        return result
    }
}
