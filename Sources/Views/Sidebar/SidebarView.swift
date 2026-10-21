import SwiftUI

import Foundation
import GeneratedModels

/// The navigation sidebar: stored sessions and the project tree.
///
/// Lists sessions from `session.list` and lets the user select one to resume.
struct SidebarView: View {
    @Environment(\.hermesClient) private var client
    @Environment(\.gatewayConnection) private var gateway

    @State private var sessions: [SessionListRow] = []
    @State private var isLoading = false

    var body: some View {
        List {
            Section("Sessions") {
                if isLoading {
                    ProgressView()
                } else if sessions.isEmpty {
                    Text("No sessions")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sessions, id: \.id) { row in
                        SessionRow(
                            row: row,
                            isSelected: gateway?.activeSession == row.id
                        ) {
                            gateway?.activeSession = row.id
                            Task { await resume(row.id) }
                        }
                    }
                }
            }

            Section("Projects") {
                Text("Project tree goes here")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
        .task { await loadSessions() }
        // Refresh the list when (re)connected, but only if we have no
        // cached sessions yet — avoid redundant session.list calls on
        // flapping reconnects.
        .onChange(of: gateway?.connectionState) { _, newState in
            if newState == .connected && sessions.isEmpty { Task { await loadSessions() } }
        }
    }

    private func loadSessions() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.listSessions()
            self.sessions = result.sessions
        } catch {
            print("loadSessions failed: \(error.localizedDescription)")
        }
    }

    private func resume(_ sessionID: String) async {
        guard let client else { return }
        do {
            _ = try await client.resumeSession(sessionID: sessionID)
        } catch {
            print("resume failed: \(error.localizedDescription)")
        }
    }
}

/// One session row in the sidebar.
private struct SessionRow: View {
    let row: SessionListRow
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(row.preview.isEmpty ? "(no messages)" : row.preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("\(row.messageCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : nil)
    }
}
