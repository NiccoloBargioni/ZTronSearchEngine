import CoreML
import Foundation

/// Which processors Core ML may schedule a model on.
///
/// A9, the reference device, has no Neural Engine, so every budget of the embedding model
/// assumes CPU inference; from A12 on, `.all` lets Core ML use the Neural Engine, which is what
/// makes the cross-encoder affordable (specification sections 7.3 and 7.4).
public enum ModelComputeUnits: Sendable, Hashable {
    /// Whatever is available: CPU, GPU and Neural Engine. The default.
    case all
    /// The CPU alone: what the reference device has, and the most reproducible timings.
    case cpuOnly
    /// CPU and GPU, never the Neural Engine.
    case cpuAndGPU
    /// CPU and Neural Engine. Needs iOS 16; earlier systems treat it as ``all``.
    case cpuAndNeuralEngine

    var coreML: MLComputeUnits {
        switch self {
        case .all:
            return .all
        case .cpuOnly:
            return .cpuOnly
        case .cpuAndGPU:
            return .cpuAndGPU
        case .cpuAndNeuralEngine:
            if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
                return .cpuAndNeuralEngine
            }
            return .all
        }
    }
}

/// The names of the features a converted transformer exposes.
///
/// The defaults are the ones the conversion scripts write and Hugging Face models use.
public struct ModelFeatureNames: Sendable, Hashable {
    /// The token ids.
    public var inputIDs: String
    /// The attention mask. Passed only when the model declares such an input.
    public var attentionMask: String
    /// The segment ids. Passed only when the model declares such an input.
    public var tokenTypeIDs: String
    /// The output to read. `nil` picks it: the model's only tensor output, or the first of the
    /// conventional names it has.
    public var output: String?

    /// Creates feature names; the defaults are those of the conversion scripts.
    public init(
        inputIDs: String = "input_ids",
        attentionMask: String = "attention_mask",
        tokenTypeIDs: String = "token_type_ids",
        output: String? = nil
    ) {
        self.inputIDs = inputIDs
        self.attentionMask = attentionMask
        self.tokenTypeIDs = tokenTypeIDs
        self.output = output
    }
}

/// A loaded sequence model: token windows in, one tensor per row out.
///
/// This is the seam between the adapters and Core ML. Everything on the adapters' side of it
/// (tokenization, batch assembly, pooling, scoring, lifecycle, the size budget) is exercised by
/// tests with a fake; only ``CoreMLSequenceModel`` below needs a real model.
///
/// A model is not `Sendable`: it lives inside the actor that loaded it.
protocol SequenceModelRunning {
    /// Runs the whole batch in one call and returns one output per row, in order.
    func predict(_ batch: ModelInputBatch) throws -> [ModelOutputRow]
}

/// What the adapters need to bring a model into memory. Production uses ``coreML``.
struct SequenceModelLoader: Sendable {
    /// What a model is for, which decides the output it is expected to have.
    enum Role: Sendable {
        case embedding
        case relevance
    }

    /// Bytes the model takes on disk.
    var footprint: @Sendable (_ modelURL: URL) throws -> Int64
    /// The tokenizer of the model: from `directory` when given, else from next to the model.
    var tokenizer: @Sendable (_ modelURL: URL, _ directory: URL?) throws -> any TextTokenizing
    /// Loads the model.
    var model: @Sendable (
        _ modelURL: URL, _ computeUnits: ModelComputeUnits, _ features: ModelFeatureNames, _ sequenceLength: Int, _ role: Role
    ) throws -> any SequenceModelRunning

    /// Core ML, and the tokenizer files next to the compiled model.
    static let coreML = SequenceModelLoader(
        footprint: { try FileAccess.footprintBlocking(of: $0) },
        tokenizer: { modelURL, directory in
            if let directory { return try TokenizerLoader.load(from: directory) }
            return try TokenizerLoader.load(forModelAt: modelURL)
        },
        model: { modelURL, computeUnits, features, sequenceLength, role in
            try CoreMLSequenceModel(
                contentsOf: modelURL, computeUnits: computeUnits, features: features, sequenceLength: sequenceLength, role: role
            )
        }
    )
}

/// A compiled Core ML transformer (`.mlmodelc`) behind ``SequenceModelRunning``.
///
/// Loading and prediction are synchronous Core ML calls. The adapters that own an instance run
/// on their own serial dispatch queue, so neither ever blocks the cooperative thread pool.
final class CoreMLSequenceModel: SequenceModelRunning {
    /// The element type the model declares for an input.
    private enum InputType {
        case int32
        case float32
        case double
    }

    private struct Input {
        var name: String
        var type: InputType
        /// The shape to send for one row; the model fixes everything but the token count.
        var shape: [Int]
    }

    private let model: MLModel
    private let inputIDs: Input
    private let attentionMask: Input?
    private let tokenTypeIDs: Input?
    private let outputName: String

    init(
        contentsOf url: URL,
        computeUnits: ModelComputeUnits,
        features: ModelFeatureNames,
        sequenceLength: Int,
        role: SequenceModelLoader.Role
    ) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits.coreML
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            throw SemanticError.modelUnavailable("cannot load \(url.lastPathComponent): \(error.localizedDescription)")
        }

        let inputs = model.modelDescription.inputDescriptionsByName
        func input(_ name: String) throws -> Input? {
            guard let description = inputs[name] else { return nil }
            guard description.type == .multiArray, let constraint = description.multiArrayConstraint else {
                throw SemanticError.modelUnavailable("the input '\(name)' is not a tensor")
            }
            let type: InputType
            switch constraint.dataType {
            case .int32: type = .int32
            case .float32: type = .float32
            case .double: type = .double
            default:
                throw SemanticError.modelUnavailable("the input '\(name)' has an element type the adapter does not feed")
            }
            // The model declares [tokens] or [1, tokens]; a dimension it leaves open is the
            // token count.
            var shape = constraint.shape.map(\.intValue)
            guard (1...2).contains(shape.count) else {
                throw SemanticError.modelUnavailable("the input '\(name)' has \(shape.count) dimensions, expected one row of tokens")
            }
            // A model converted with a fixed window must be fed exactly that window. A model
            // with a flexible or enumerated shape is left to Core ML to check.
            let declared = shape[shape.count - 1]
            if constraint.shapeConstraint.type == .unspecified, declared != sequenceLength {
                throw SemanticError.modelUnavailable(
                    "the model takes \(declared) tokens, the adapter is configured for \(sequenceLength)"
                )
            }
            shape[shape.count - 1] = sequenceLength
            if shape.count == 2 { shape[0] = 1 }
            return Input(name: name, type: type, shape: shape)
        }

        guard let ids = try input(features.inputIDs) else {
            throw SemanticError.modelUnavailable(
                "the model has no input named '\(features.inputIDs)'; its inputs are \(inputs.keys.sorted())"
            )
        }
        inputIDs = ids
        attentionMask = try input(features.attentionMask)
        tokenTypeIDs = try input(features.tokenTypeIDs)
        let fed: Set<String> = [features.inputIDs, features.attentionMask, features.tokenTypeIDs]
        if let extra = inputs.keys.sorted().first(where: { !fed.contains($0) && inputs[$0]?.isOptional == false }) {
            throw SemanticError.modelUnavailable("the model requires an input the adapter does not feed: '\(extra)'")
        }

        let tensors = model.modelDescription.outputDescriptionsByName.filter { $0.value.type == .multiArray }.keys.sorted()
        if let requested = features.output {
            guard tensors.contains(requested) else {
                throw SemanticError.modelUnavailable("the model has no tensor output named '\(requested)'; its outputs are \(tensors)")
            }
            outputName = requested
        } else if tensors.count == 1 {
            outputName = tensors[0]
        } else {
            let conventional: [String]
            switch role {
            case .embedding:
                conventional = ["sentence_embedding", "pooler_output", "embeddings", "token_embeddings", "last_hidden_state"]
            case .relevance:
                conventional = ["logits", "scores", "score"]
            }
            guard let match = conventional.first(where: tensors.contains) else {
                throw SemanticError.modelUnavailable("cannot tell which output to read among \(tensors); name it in the configuration")
            }
            outputName = match
        }
    }

    func predict(_ batch: ModelInputBatch) throws -> [ModelOutputRow] {
        guard batch.rowCount > 0 else { return [] }
        do {
            var rows: [any MLFeatureProvider] = []
            rows.reserveCapacity(batch.rowCount)
            for row in 0..<batch.rowCount {
                var features: [String: MLFeatureValue] = [inputIDs.name: value(batch.inputIDs(row: row), for: inputIDs)]
                if let attentionMask {
                    features[attentionMask.name] = value(batch.attentionMask(row: row), for: attentionMask)
                }
                if let tokenTypeIDs {
                    features[tokenTypeIDs.name] = value(batch.tokenTypeIDs(row: row), for: tokenTypeIDs)
                }
                rows.append(try MLDictionaryFeatureProvider(dictionary: features))
            }
            // One call for the whole batch.
            let results = try model.predictions(fromBatch: MLArrayBatchProvider(array: rows))
            guard results.count == batch.rowCount else {
                throw SemanticError.unexpectedModelOutput("\(results.count) results for \(batch.rowCount) rows")
            }
            return try (0..<results.count).map { index in
                guard let array = results.features(at: index).featureValue(for: outputName)?.multiArrayValue else {
                    throw SemanticError.unexpectedModelOutput("the output '\(outputName)' is missing from a result")
                }
                let tensor = MLShapedArray<Float>(converting: array)
                return ModelOutputRow(shape: tensor.shape, values: tensor.scalars)
            }
        } catch let error as SemanticError {
            throw error
        } catch {
            throw SemanticError.modelUnavailable("prediction failed: \(error.localizedDescription)")
        }
    }

    private func value(_ tokens: ArraySlice<Int32>, for input: Input) -> MLFeatureValue {
        switch input.type {
        case .int32:
            return MLFeatureValue(multiArray: MLMultiArray(MLShapedArray<Int32>(scalars: tokens, shape: input.shape)))
        case .float32:
            return MLFeatureValue(multiArray: MLMultiArray(MLShapedArray<Float>(scalars: tokens.map(Float.init), shape: input.shape)))
        case .double:
            return MLFeatureValue(multiArray: MLMultiArray(MLShapedArray<Double>(scalars: tokens.map(Double.init), shape: input.shape)))
        }
    }
}

/// Runs an actor on a private serial dispatch queue instead of the cooperative thread pool.
///
/// Core ML loads and predicts synchronously, and both can take hundreds of milliseconds. An
/// actor that makes those calls on the cooperative pool would block one of its few threads
/// (specification section 11, rule 7). An actor that names this executor runs every one of its
/// jobs on its own queue, so the blocking call blocks nothing else, and its state stays
/// ordinary isolated actor state.
final class SerialQueueExecutor: SerialExecutor {
    private let queue: DispatchQueue

    init(label: String, qos: DispatchQoS = .userInitiated) {
        queue = DispatchQueue(label: label, qos: qos)
    }

    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedSerialExecutor()
        queue.async {
            job.runSynchronously(on: executor)
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}
