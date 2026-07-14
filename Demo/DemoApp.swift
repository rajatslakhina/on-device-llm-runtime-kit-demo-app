import SwiftUI
import LLMRuntimeKit

/// Runtime Lab — a playground over `LLMRuntimeKit`'s full pipeline:
/// device-profile knobs → auditable runtime/quantization selection →
/// pin-counted model loading → streaming chat with live KV accounting →
/// memory/thermal pressure injection via the resource governor.
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RuntimeLabView()
        }
    }
}
