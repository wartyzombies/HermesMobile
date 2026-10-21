import SwiftUI

import Foundation
import GeneratedModels

/// The active session transcript with the message composer docked below.
///
/// Renders the transcript (message.delta / message.complete), tool-call cards
/// (tool.start / tool.complete), approval dialogs (approval.received →
/// approval.respond), a model picker (model.options), and a composer that
/// submits prompts via `prompt.submit`.
struct ChatView: View {
    @Environment(\.hermesClient) private var client
    @Environment(\.gatewayConnection) private var gateway
    @Environment(\.transcriptStore) private var store

    @State private var showingModelPicker = false
    @State private var showingApproval = false
    @State private var showingCommands = false
    @State private var pendingApproval: ApprovalRequest?
    @State private var modelOptions: [String: [String]] = [:]
    @State private var modelOptionsLoaded = false

    var body: some View {
        Group {
            if let sessionID = gateway?.activeSession {
                main(sessionID: sessionID)
            } else {
                emptyState
            }
        }
        .sheet(isPresented: $showingCommands) {
            if let sessionID = gateway?.activeSession {
                NavigationStack {
                    CommandsView(sessionID: sessionID)
                }
            }
        }
        // (Re)load history whenever the active session changes.
        .onChange(of: gateway?.activeSession) { _, newValue in
            if let newValue { Task { await loadHistory(newValue) } }
            modelOptionsLoaded = false
        }
        // Present an approval dialog whenever the gateway requests one.
        .onChange(of: gateway?.approvalTrigger) { _, _ in
            if let request = gateway?.approvalManager.pending {
                pendingApproval = request
                showingApproval = true
            }
        }
        .confirmationDialog("Choose model", isPresented: $showingModelPicker, titleVisibility: .visible) {
            modelPickerButtons
        } message: {
            Text("Select a model for the active session.")
        }
        .alert("Approval required", isPresented: $showingApproval) {
            approvalButtons
        } message: {
            Text(approvalMessage)
        }
        .task {
            if let sid = gateway?.activeSession { await loadHistory(sid) }
            await loadModelOptions()
        }
    }

    // MARK: - View builders

    @ViewBuilder
    private func main(sessionID: String) -> some View {
        VStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store?.messages ?? []) { message in
                        MessageBubble(message: message)
                    }
                }
                .padding()
            }
            ComposerView(sessionID: sessionID)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(sessionTitle).font(.headline)
            }
            ToolbarItem(placement: toolbarTrailingPlacement) {
                Button("Model") {
                    modelOptionsLoaded = false
                    showingModelPicker = true
                }
            }
            ToolbarItem(placement: toolbarTrailingPlacement) {
                Button("Commands") {
                    showingCommands = true
                }
            }
        }
    }

    /// `.navigationBarTrailing` is iOS-only; macOS places items automatically.
    private var toolbarTrailingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        return .navigationBarTrailing
        #else
        return .automatic
        #endif
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Session",
            systemImage: "bubble.left.and.bubble.right.slash",
            description: Text("Select a session from the sidebar to start chatting.")
        )
    }

    @ViewBuilder
    private var modelPickerButtons: some View {
        if !modelOptionsLoaded {
            ProgressView("Loading models…")
        } else if modelOptions.isEmpty {
            Text("No models available")
        } else {
            ForEach(Array(modelOptions.keys.sorted()), id: \.self) { providerName in
                Section(providerName) {
                    ForEach(modelOptions[providerName] ?? [], id: \.self) { model in
                        Button(model) {
                            Task { await selectModel(model) }
                            showingModelPicker = false
                        }
                    }
                }
            }
        }
        Button("Cancel", role: .cancel) { }
    }

    @ViewBuilder
    private var approvalButtons: some View {
        if let request = pendingApproval {
            let choices = request.approval.choices ?? ["once", "session", "always", "deny"]
            ForEach(choices, id: \.self) { choice in
                Button(choice.capitalized) {
                    respond(to: request, choice: choice)
                    showingApproval = false
                }
            }
            Button("Cancel", role: .cancel) {
                showingApproval = false
            }
        }
    }

    // MARK: - Actions

    private var sessionTitle: String {
        gateway?.activeSession ?? "Session"
    }

    private var approvalMessage: String {
        guard let request = pendingApproval else { return "" }
        let parts = [
            request.approval.command.map { "Command: \($0)" },
            request.approval.description.map { $0 }
        ].compactMap { $0 }
        return parts.joined(separator: "\n")
    }

    private func loadHistory(_ sessionID: String) async {
        guard let client else { return }
        do {
            let result = try await client.sessionHistory(sessionID: sessionID)
            let messages = result.messages.map { wire in
                ChatMessage(
                    id: wire.toolCallId ?? UUID().uuidString,
                    text: wire.text ?? "",
                    role: ChatMessage.Role(rawValue: wire.role) ?? .assistant,
                    reasoning: wire.reasoning
                )
            }
            store?.replace(messages: messages)
        } catch {
            print("loadHistory failed: \(error.localizedDescription)")
        }
    }

    private func loadModelOptions() async {
        guard let client else { return }
        do {
            let result = try await client.modelOptions()
            var dict: [String: [String]] = [:]
            for provider in result.providers {
                dict[provider.name] = provider.models ?? []
            }
            modelOptions = dict
            modelOptionsLoaded = true
        } catch {
            print("modelOptions failed: \(error.localizedDescription)")
            modelOptions = [:]
            modelOptionsLoaded = true
        }
    }

    private func selectModel(_ model: String) async {
        guard let client, let sessionID = gateway?.activeSession else { return }
        do {
            _ = try await client.configSet(
                sessionID: sessionID,
                key: "model",
                value: .string(model)
            )
        } catch {
            // Non-fatal; picker still closes.
        }
    }

    private func respond(to request: ApprovalRequest, choice: String) {
        // If the approval arrived on a gateway-initiated JSON-RPC request,
        // answer that request directly; otherwise fall back to the
        // `approval.respond` RPC.
        if let respond = request.respond {
            respond(choice)
            return
        }
        guard let client else { return }
        let sessionID = request.sessionId.isEmpty
            ? (gateway?.activeSession ?? "")
            : request.sessionId
        guard !sessionID.isEmpty else { return }
        Task {
            do {
                _ = try await client.respondApproval(
                    sessionID: sessionID,
                    choice: ApprovalChoice(rawValue: choice)
                )
            } catch {
                print("respondApproval failed: \(error.localizedDescription)")
            }
        }
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reasoning = message.reasoning, !reasoning.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reasoning").font(.caption2).foregroundStyle(.secondary)
                    Text(reasoning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
            Text(message.text)
                .textSelection(.enabled)
            ForEach(message.toolCalls) { tool in
                ToolCallRow(tool: tool)
            }
        }
        .padding(8)
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
        .background(message.role == .user ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct ToolCallRow: View {
    let tool: ToolCall

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "wrench.and.screwdriver")
            Text(tool.name).font(.caption).fontWeight(.medium)
            if let result = tool.result, !result.isEmpty {
                Image(systemName: "checkmark.seal").foregroundStyle(.green)
                Spacer(minLength: 6)
                Text(result)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
    }
}
