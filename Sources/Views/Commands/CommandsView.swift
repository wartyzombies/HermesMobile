import SwiftUI

import Foundation

/// Slash-command catalog: lists available commands grouped by category
/// and lets the user execute one via `slash.exec`.
struct CommandsView: View {
    @Environment(\.hermesClient) private var client
    @Environment(\.gatewayConnection) private var gateway

    let sessionID: String

    @State private var categories: [CommandCategory] = []
    @State private var isLoading = false
    @State private var executing = false
    @State private var execMessage: String?

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading commands…")
            } else if categories.isEmpty {
                ContentUnavailableView(
                    "No commands",
                    systemImage: "keyboard",
                    description: Text("No slash commands are available for this session.")
                )
            } else {
                ForEach(categories, id: \.name) { category in
                    Section(category.name) {
                        ForEach(category.pairs ?? [], id: \.self) { pair in
                            let name = pair.first ?? ""
                            let arg = pair.dropFirst().first ?? ""
                            Button {
                                Task { await execute(name, arg: arg) }
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("/\(name)")
                                        .font(.headline)
                                        .monospaced()
                                    if !arg.isEmpty {
                                        Text(arg)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(executing)
                        }
                    }
                }
            }
        }
        .navigationTitle("Slash Commands")
        .task { await load() }
        .alert("Result", isPresented: .constant(execMessage != nil)) {
            Button("OK", role: .cancel) { execMessage = nil }
        } message: {
            Text(execMessage ?? "")
        }
    }

    private func load() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.commandsCatalog()
            self.categories = result.categories ?? []
        } catch {
            execMessage = error.localizedDescription
        }
    }

    private func execute(_ name: String, arg: String) async {
        guard let client else { return }
        executing = true
        defer { executing = false }
        do {
            let result = try await client.slashExec(sessionID: sessionID, command: name)
            execMessage = result.display ?? result.message ?? result.output ?? "Executed /\(name)"
        } catch {
            execMessage = error.localizedDescription
        }
    }
}

/// A command row's name + optional argument, as returned by `commands.catalog`.
private struct CommandEntry: Identifiable {
    let id: String
    let name: String
    let arg: String
}
