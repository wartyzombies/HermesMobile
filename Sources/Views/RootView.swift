import SwiftUI

/// Root two-column navigation view: sidebar + chat.
///
/// Matches the Hermes Desktop layout — a navigation sidebar listing
/// sessions and projects, with the active transcript as the detail.
struct RootView: View {
    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            ChatView()
        }
    }
}
