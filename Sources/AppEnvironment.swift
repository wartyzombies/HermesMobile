import SwiftUI

/// Single source of truth for all `@Environment` keys used by the M4 UI views.
///
/// Views reach the transport, connection, transcript store, and active
/// session through these keys; the app shell injects the live values once.
private struct HermesClientKey: EnvironmentKey {
    static let defaultValue: HermesClient? = nil
}

private struct GatewayConnectionKey: EnvironmentKey {
    static let defaultValue: GatewayConnection? = nil
}

private struct TranscriptStoreKey: EnvironmentKey {
    static let defaultValue: TranscriptStore? = nil
}

extension EnvironmentValues {
    /// The shared `HermesClient`, or `nil` before the shell wires it.
    var hermesClient: HermesClient? {
        get { self[HermesClientKey.self] }
        set { self[HermesClientKey.self] = newValue }
    }

    /// The live `GatewayConnection`, or `nil` before the shell wires it.
    var gatewayConnection: GatewayConnection? {
        get { self[GatewayConnectionKey.self] }
        set { self[GatewayConnectionKey.self] = newValue }
    }

    /// The transcript store, or `nil` before the shell wires it.
    var transcriptStore: TranscriptStore? {
        get { self[TranscriptStoreKey.self] }
        set { self[TranscriptStoreKey.self] = newValue }
    }
}