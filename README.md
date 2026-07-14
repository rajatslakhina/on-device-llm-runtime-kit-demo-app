# Runtime Lab — LLMRuntimeKit demo app

**Watch an on-device LLM stack make its hardest decision — "which runtime, which quantization, on *this* device?" — and then survive memory warnings and thermal throttling while it streams.**

This app is a laboratory over [`LLMRuntimeKit`](https://github.com/rajatslakhina/on-device-llm-runtime-kit): drag the device profile around (usable memory, thermal state, Neural Engine availability), pick a model, and see the full, auditable selection decision — not just the winner, but every rejected (runtime × quantization) pair with the exact bytes and reasons behind it. Then load the model, chat with a streaming simulated backend, watch the KV cache gauge grow token by token, and inject memory-pressure and thermal signals to watch the resource governor trim caches and evict idle models in real time.

## Why this matters

Runtime selection is the decision every on-device AI team makes once, on a whiteboard, for the average device — and then relitigates in production for every device that wasn't average. This demo makes the whole decision surface *manipulable*: set memory to 2 GB and watch q8 get priced out with the exact projected-vs-allowed byte counts; flip thermal state to `serious` and watch the objective degrade to smallest-footprint; kill the Neural Engine and watch Core ML disqualify itself. The rejection log the app shows is the same audit trail the library returns in production — the difference between "the model didn't load, shrug" and a bug report that answers itself.

## What to try

1. **Decide** with defaults → MLX or llama.cpp wins depending on the model's format; open "Rejections" to see why everything else lost.
2. Drop **usable memory to 2 GB** → the q8 quantizations disappear from contention with `insufficientMemory` and exact numbers.
3. Set **thermal to Serious** → the effective objective flips to memory-headroom (the decision card says so) and the smallest quantization wins.
4. **Load & chat** → tokens stream in; the stats line reports prompt tokens, TTFT, and tokens/sec; the KV gauge grows as context accumulates.
5. Tap **Memory warning / Critical / Thermal critical** → the governor trims the KV store (and, at critical memory pressure, evicts idle models), and its action log explains each move.

The backend is `LLMRuntimeKit`'s bundled `SimulatedInferenceBackend` — deterministic and clearly documented as a simulation — so the *system* (selection, loading, budgeting, rollback, governance) is what's on display, with no model weights required.

## How to run it

1. Open `Demo.xcodeproj` in Xcode (16+).
2. Xcode resolves the `LLMRuntimeKit` package automatically from its GitHub URL — this project consumes the library as a **remote** Swift Package dependency (`XCRemoteSwiftPackageReference`, branch `main`), the same way any external consumer would. No local checkout of the library is needed or referenced.
3. Select the `Demo` scheme, pick any iOS 17+ Simulator, and **Run**.

## Companion library

The engine lives in [`on-device-llm-runtime-kit`](https://github.com/rajatslakhina/on-device-llm-runtime-kit) — runtime/quantization selection, single-flight pin-counted model loading, byte-budgeted KV caching, transactional streaming sessions, and the resource governor, with **56 XCTest cases** (all passing on Swift 6.0.3, strict-concurrency mode) covering the failure modes this demo lets you trigger by hand.

## Verification status (honest)

- The library this app consumes was verified for real: `swift build` + `swift test` — **56/56 tests passing, zero warnings** (Swift 6.0.3, Linux).
- This app's three Swift files pass `swiftc -parse` (SwiftUI cannot resolve headlessly); `project.pbxproj` is brace/paren-balanced with all 24 object IDs cross-referenced (zero dangling); the shared scheme is XML-validated; there are zero force-unwraps.
- **This app has *not* been run on a Simulator, and no screenshots exist.** This pipeline runs unattended; computer-use access to Xcode/Simulator was requested twice this run and refused both times with "Computer-use access can't be approved during a scheduled run" — a hard platform block, consistent with every prior scheduled run of this pipeline. Rather than fake a screenshot or claim a launch that didn't happen, this README says so plainly. The honest ceiling is: library fully build- and test-verified; app statically verified only.
