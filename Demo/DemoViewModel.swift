import SwiftUI
import LLMRuntimeKit

// MARK: - View-facing types

struct ChatLine: Identifiable, Hashable {
    enum Role: Hashable {
        case user
        case assistant
        case system
    }

    let id = UUID()
    let role: Role
    var text: String
}

struct CatalogEntry: Identifiable, Hashable {
    let id: String
    let manifest: ModelManifest
    let subtitle: String
}

// MARK: - View model

/// Drives the whole `LLMRuntimeKit` pipeline from UI state. `@MainActor` by
/// design: every property the view reads is mutated on the main actor, and
/// the kit's actors are awaited from here.
@MainActor
@Observable
final class DemoViewModel {
    // MARK: Fixed infrastructure

    let catalog: [CatalogEntry]
    let runtimes: [RuntimeDescriptor]
    private let backends: [String: SimulatedInferenceBackend]
    private let loader = ModelLoader(budgetBytes: 6_000_000_000)
    private let kvStore = KVCacheStore(budgetBytes: 64_000_000)
    private let governor: ResourceGovernor

    // MARK: Device knobs

    var usableMemoryGB = 4.0
    var thermalState: ThermalState = .nominal
    var hasNeuralEngine = true
    var objective: SelectionPolicy.Objective = .maximizeQuality

    // MARK: Selection state

    var selectedModelID: String
    private(set) var decision: SelectionDecision?

    // MARK: Session state

    var prompt = ""
    private(set) var transcript: [ChatLine] = []
    private(set) var isStreaming = false
    private(set) var lastStats: GenerationStats?
    private(set) var statusMessage = "Pick a model, then Decide."

    // MARK: Resource gauges

    private(set) var kvUsageBytes: Int64 = 0
    private(set) var kvBudgetBytes: Int64 = 64_000_000
    private(set) var loadedModelBytes: Int64 = 0
    private(set) var governorLog: [String] = []

    private var session: InferenceSession?
    private var pinnedModel: LoadedModel?

    init() {
        let mlx = RuntimeDescriptor(
            id: "mlx", displayName: "MLX",
            supportedFormats: [.mlxSafetensors],
            minimumOSMajorVersion: 17, requiresNeuralEngine: false,
            memoryOverheadFactor: 1.15, throughputScore: 0.9, supportsStreaming: true
        )
        let coreML = RuntimeDescriptor(
            id: "coreml", displayName: "Core ML",
            supportedFormats: [.coreMLPackage],
            minimumOSMajorVersion: 17, requiresNeuralEngine: true,
            memoryOverheadFactor: 1.35, throughputScore: 0.75, supportsStreaming: true
        )
        let llamaCpp = RuntimeDescriptor(
            id: "llamacpp", displayName: "llama.cpp",
            supportedFormats: [.gguf],
            minimumOSMajorVersion: 15, requiresNeuralEngine: false,
            memoryOverheadFactor: 1.1, throughputScore: 0.6, supportsStreaming: true
        )
        let foundation = RuntimeDescriptor(
            id: "foundation-models", displayName: "Foundation Models",
            supportedFormats: [.foundationModels],
            minimumOSMajorVersion: 26, requiresNeuralEngine: true,
            memoryOverheadFactor: 1.05, throughputScore: 0.7, supportsStreaming: true
        )
        runtimes = [mlx, coreML, llamaCpp, foundation]

        var backendMap: [String: SimulatedInferenceBackend] = [:]
        for runtime in runtimes {
            let delay: UInt64
            switch runtime.id {
            case "mlx": delay = 40_000_000
            case "coreml": delay = 60_000_000
            case "foundation-models": delay = 50_000_000
            default: delay = 90_000_000
            }
            backendMap[runtime.id] = SimulatedInferenceBackend(
                descriptor: runtime,
                behavior: .init(
                    loadDelayNanoseconds: 300_000_000,
                    tokenDelayNanoseconds: delay,
                    replyProvider: { prompt in
                        let intro = "[\(runtime.displayName) · simulated] Thinking about"
                        let words = prompt.split(separator: " ").prefix(12).map { "'\($0)'" }
                        let body = words.isEmpty ? ["an", "empty", "prompt"] : words
                        return (intro.split(separator: " ").map(String.init))
                            + body
                            + ["—", "this", "reply", "streams", "token", "by", "token",
                               "so", "KV", "growth", "and", "throughput", "stay", "visible."]
                    }
                )
            )
        }
        backends = backendMap

        let atlasQuants = [
            QuantizationOption(name: "q4", bitsPerWeight: 4,
                               estimatedMemoryBytes: 1_900_000_000,
                               estimatedDiskBytes: 1_700_000_000, qualityScore: 0.82),
            QuantizationOption(name: "q8", bitsPerWeight: 8,
                               estimatedMemoryBytes: 3_400_000_000,
                               estimatedDiskBytes: 3_200_000_000, qualityScore: 0.94)
        ]
        let entries = [
            CatalogEntry(
                id: "atlas-3b-gguf",
                manifest: ModelManifest(
                    id: "atlas-3b-gguf", displayName: "Atlas 3B (GGUF)",
                    parameterCount: 3_000_000_000, format: .gguf,
                    contextWindowTokens: 4096, kvBytesPerToken: 16_384,
                    quantizations: atlasQuants
                ),
                subtitle: "3B · GGUF · q4/q8"
            ),
            CatalogEntry(
                id: "atlas-3b-mlx",
                manifest: ModelManifest(
                    id: "atlas-3b-mlx", displayName: "Atlas 3B (MLX)",
                    parameterCount: 3_000_000_000, format: .mlxSafetensors,
                    contextWindowTokens: 4096, kvBytesPerToken: 16_384,
                    quantizations: atlasQuants
                ),
                subtitle: "3B · MLX safetensors · q4/q8"
            ),
            CatalogEntry(
                id: "nano-1b-coreml",
                manifest: ModelManifest(
                    id: "nano-1b-coreml", displayName: "Nano 1B (Core ML)",
                    parameterCount: 1_000_000_000, format: .coreMLPackage,
                    contextWindowTokens: 2048, kvBytesPerToken: 8_192,
                    quantizations: [
                        QuantizationOption(name: "int8", bitsPerWeight: 8,
                                           estimatedMemoryBytes: 700_000_000,
                                           estimatedDiskBytes: 650_000_000, qualityScore: 0.74),
                        QuantizationOption(name: "fp16", bitsPerWeight: 16,
                                           estimatedMemoryBytes: 1_300_000_000,
                                           estimatedDiskBytes: 1_200_000_000, qualityScore: 0.8)
                    ]
                ),
                subtitle: "1B · Core ML · int8/fp16"
            ),
            CatalogEntry(
                id: "system-base",
                manifest: ModelManifest(
                    id: "system-base", displayName: "System model",
                    parameterCount: 3_000_000_000, format: .foundationModels,
                    contextWindowTokens: 4096, kvBytesPerToken: 12_288,
                    quantizations: [
                        QuantizationOption(name: "system", bitsPerWeight: 4,
                                           estimatedMemoryBytes: 950_000_000,
                                           estimatedDiskBytes: 0, qualityScore: 0.88)
                    ]
                ),
                subtitle: "OS-provided · no weights shipped"
            )
        ]
        catalog = entries
        selectedModelID = entries[0].id
        governor = ResourceGovernor(kvStore: kvStore, loader: loader)
    }

    // MARK: Derived

    var currentDevice: DeviceProfile {
        let usable = Int64(usableMemoryGB * 1_073_741_824)
        return DeviceProfile(
            totalMemoryBytes: usable * 2,
            usableMemoryBytes: usable,
            hasNeuralEngine: hasNeuralEngine,
            osMajorVersion: 27,
            freeDiskBytes: 64_000_000_000,
            thermalState: thermalState
        )
    }

    var selectedEntry: CatalogEntry? {
        catalog.first { $0.id == selectedModelID }
    }

    // MARK: Actions

    func decide() {
        guard let entry = selectedEntry else { return }
        let policy = SelectionPolicy(
            objective: objective,
            requiredMemoryHeadroomFraction: 0.2,
            maxThermalState: .fair,
            degradeUnderThermalPressure: true,
            requireStreaming: true
        )
        decision = RuntimeSelector().select(
            model: entry.manifest,
            device: currentDevice,
            runtimes: runtimes,
            policy: policy
        )
        if let choice = decision?.selected {
            statusMessage = "Decision: \(choice.runtime.displayName) · \(choice.quantization.name). Load to chat."
        } else {
            statusMessage = "No viable (runtime × quantization) — see the rejection log."
        }
    }

    func loadSelected() {
        guard let entry = selectedEntry,
              let choice = decision?.selected,
              let backend = backends[choice.runtime.id] else {
            statusMessage = "Decide first — loading follows the decision."
            return
        }
        statusMessage = "Loading \(entry.manifest.displayName) [\(choice.quantization.name)]…"
        Task {
            do {
                if let old = pinnedModel {
                    await loader.release(old)
                    pinnedModel = nil
                }
                if let oldSession = session {
                    await kvStore.remove(sessionID: oldSession.id)
                    session = nil
                }
                let model = try await loader.acquire(
                    manifest: entry.manifest,
                    quantization: choice.quantization,
                    backend: backend
                )
                pinnedModel = model
                session = await InferenceSession(
                    model: model, backend: backend, kvStore: kvStore
                )
                transcript.append(ChatLine(
                    role: .system,
                    text: "Loaded \(entry.manifest.displayName) [\(choice.quantization.name)] on \(choice.runtime.displayName)."
                ))
                statusMessage = "Ready — session pinned to \(choice.runtime.displayName)."
            } catch {
                statusMessage = "Load failed: \(describe(error))"
            }
            await refreshGauges()
        }
    }

    func send() {
        guard !isStreaming else { return }
        guard let session else {
            statusMessage = "Load a model first."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompt = ""
        transcript.append(ChatLine(role: .user, text: text))
        transcript.append(ChatLine(role: .assistant, text: ""))
        isStreaming = true
        Task {
            do {
                let stream = try await session.respond(to: text, maxTokens: 64)
                for try await event in stream {
                    switch event {
                    case .started:
                        break
                    case .token(let token):
                        appendToOpenAssistantLine(token + " ")
                        await refreshGauges()
                    case .finished(let stats):
                        lastStats = stats
                    }
                }
            } catch {
                appendToOpenAssistantLine("⚠️ \(describe(error))")
            }
            isStreaming = false
            await refreshGauges()
        }
    }

    func inject(_ signal: ResourceSignal) {
        Task {
            await governor.handle(signal)
            let actions = await governor.drainActionLog()
            governorLog.append(contentsOf: actions.map(describe))
            if governorLog.count > 8 {
                governorLog.removeFirst(governorLog.count - 8)
            }
            await refreshGauges()
        }
    }

    // MARK: Internals

    private func refreshGauges() async {
        kvUsageBytes = await kvStore.usageBytes
        loadedModelBytes = await loader.loadedBytes
    }

    private func appendToOpenAssistantLine(_ suffix: String) {
        guard !transcript.isEmpty else { return }
        let lastIndex = transcript.count - 1 // safe: emptiness checked above
        guard transcript[lastIndex].role == .assistant else { return }
        transcript[lastIndex].text += suffix
    }

    private func describe(_ action: GovernorAction) -> String {
        switch action {
        case .trimmedKVCache(let fraction, let freed):
            return "KV trimmed to \(Int(fraction * 100))% — freed \(ByteFormat.string(freed))"
        case .unloadedIdleModels(let freed):
            return "Idle models unloaded — freed \(ByteFormat.string(freed))"
        case .noAction(let signal):
            return "Observed \(String(describing: signal)) — no action (by policy)"
        }
    }

    private func describe(_ error: Error) -> String {
        if case LoaderError.budgetExceeded(let required, let budget, let reclaimable) = error {
            return "Budget exceeded: needs \(ByteFormat.string(required)), budget \(ByteFormat.string(budget)), reclaimable \(ByteFormat.string(reclaimable))"
        }
        return String(describing: error)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }
}
