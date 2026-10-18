import SwiftUI

/// Root view: an auth gate until a gateway session is established, then the
/// two-column navigation view (sidebar + chat).
struct RootView: View {
    @Environment(\.gatewayConnection) private var gateway

    var body: some View {
        Group {
            if gateway?.connectionState == .connected {
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    ChatView()
                }
            } else {
                AuthGateView()
            }
        }
    }
}
