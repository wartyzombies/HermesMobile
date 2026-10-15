import SwiftUI

/// The `HermesClient` available to every view via
/// `@Environment(\.hermesClient)`.
///
/// Injected once by the app shell (`HermesMobileApp`) so views can
/// issue RPCs without holding a direct reference to the transport.
private struct HermesClientKey: EnvironmentKey {
    static let defaultValue: HermesClient? = nil
}

extension EnvironmentValues {
    /// The shared `HermesClient`, or `nil` before the shell wires it.
    var hermesClient: HermesClient? {
        get { self[HermesClientKey.self] }
        set { self[HermesClientKey.self] = newValue }
    }
}
