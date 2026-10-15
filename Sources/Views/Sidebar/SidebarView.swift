import SwiftUI

/// The navigation sidebar: stored sessions and the project tree.
///
/// Placeholder sections that the session list and project browser will
/// populate; they mirror the Hermes Desktop sidebar.
struct SidebarView: View {
    var body: some View {
        List {
            Section("Sessions") {
                Text("Session list goes here")
            }
            Section("Projects") {
                Text("Project tree goes here")
            }
        }
        .listStyle(.sidebar)
    }
}
