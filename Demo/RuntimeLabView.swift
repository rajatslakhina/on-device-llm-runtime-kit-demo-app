import SwiftUI
import LLMRuntimeKit

struct RuntimeLabView: View {
    @State private var model = DemoViewModel()

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                selectionSection
                chatSection
                resourceSection
            }
            .navigationTitle("Runtime Lab")
        }
    }

    // MARK: Device knobs

    private var deviceSection: some View {
        Section("Device profile") {
            VStack(alignment: .leading) {
                Text("Usable memory: \(model.usableMemoryGB, specifier: "%.1f") GB")
                    .font(.subheadline)
                Slider(value: $model.usableMemoryGB, in: 2...12, step: 0.5)
            }
            Picker("Thermal state", selection: $model.thermalState) {
                Text("Nominal").tag(ThermalState.nominal)
                Text("Fair").tag(ThermalState.fair)
                Text("Serious").tag(ThermalState.serious)
                Text("Critical").tag(ThermalState.critical)
            }
            Toggle("Neural Engine available", isOn: $model.hasNeuralEngine)
            Picker("Objective", selection: $model.objective) {
                Text("Quality").tag(SelectionPolicy.Objective.maximizeQuality)
                Text("Throughput").tag(SelectionPolicy.Objective.maximizeThroughput)
                Text("Headroom").tag(SelectionPolicy.Objective.maximizeMemoryHeadroom)
            }
        }
    }

    // MARK: Selection

    private var selectionSection: some View {
        Section("Model & decision") {
            Picker("Model", selection: $model.selectedModelID) {
                ForEach(model.catalog) { entry in
                    Text(entry.manifest.displayName).tag(entry.id)
                }
            }
            Button("Decide runtime × quantization") {
                model.decide()
            }
            if let decision = model.decision {
                decisionView(decision)
            }
            Text(model.statusMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func decisionView(_ decision: SelectionDecision) -> some View {
        if let choice = decision.selected {
            VStack(alignment: .leading, spacing: 4) {
                Label("\(choice.runtime.displayName) · \(choice.quantization.name)",
                      systemImage: "checkmark.seal.fill")
                    .font(.headline)
                Text("Projected resident: \(ByteFormat.string(choice.projectedMemoryBytes)) · headroom \(Int(choice.projectedHeadroomFraction * 100))% · objective \(decision.effectiveObjective.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Load model & open session") {
                model.loadSelected()
            }
        }
        if !decision.rejected.isEmpty {
            DisclosureGroup("Rejections (\(decision.rejected.count))") {
                ForEach(Array(decision.rejected.enumerated()), id: \.offset) { _, rejection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(rejection.runtimeID)\(rejection.quantizationName.map { " · \($0)" } ?? "")")
                            .font(.caption.bold())
                        Text(rejection.reason.description)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // MARK: Chat

    private var chatSection: some View {
        Section("Session") {
            if model.transcript.isEmpty {
                Text("No turns yet — load a model, then send a prompt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.transcript) { line in
                    transcriptRow(line)
                }
            }
            if let stats = model.lastStats {
                Text("prompt \(stats.promptTokens) tok · generated \(stats.generatedTokens) tok · TTFT \(stats.timeToFirstToken.map { String(format: "%.2fs", $0) } ?? "–") · \(String(format: "%.1f", stats.tokensPerSecond)) tok/s · \(stats.stopReason.rawValue)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField("Prompt", text: $model.prompt)
                    .textFieldStyle(.roundedBorder)
                Button(action: { model.send() }) {
                    Image(systemName: model.isStreaming ? "hourglass" : "paperplane.fill")
                }
                .disabled(model.isStreaming)
            }
        }
    }

    private func transcriptRow(_ line: ChatLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            switch line.role {
            case .user:
                Image(systemName: "person.fill").foregroundStyle(.blue)
            case .assistant:
                Image(systemName: "cpu").foregroundStyle(.green)
            case .system:
                Image(systemName: "info.circle").foregroundStyle(.secondary)
            }
            Text(line.text.isEmpty ? "…" : line.text)
                .font(line.role == .system ? .caption : .body)
                .foregroundStyle(line.role == .system ? .secondary : .primary)
        }
    }

    // MARK: Resources

    private var resourceSection: some View {
        Section("Resources & governor") {
            VStack(alignment: .leading, spacing: 4) {
                Text("KV cache: \(ByteFormat.string(model.kvUsageBytes)) / \(ByteFormat.string(model.kvBudgetBytes))")
                    .font(.caption)
                ProgressView(value: gaugeFraction(model.kvUsageBytes, model.kvBudgetBytes))
                Text("Models resident: \(ByteFormat.string(model.loadedModelBytes))")
                    .font(.caption)
            }
            HStack {
                Button("Memory warning") {
                    model.inject(.memoryPressure(.warning))
                }
                .buttonStyle(.bordered)
                Button("Critical") {
                    model.inject(.memoryPressure(.critical))
                }
                .buttonStyle(.bordered)
                Button("Thermal critical") {
                    model.inject(.thermal(.critical))
                }
                .buttonStyle(.bordered)
            }
            .font(.caption)
            if !model.governorLog.isEmpty {
                ForEach(Array(model.governorLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func gaugeFraction(_ used: Int64, _ budget: Int64) -> Double {
        guard budget > 0 else { return 0 }
        return min(max(Double(used) / Double(budget), 0), 1)
    }
}

#Preview {
    RuntimeLabView()
}
