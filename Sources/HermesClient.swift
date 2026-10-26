//
//  HermesClient.swift
//  Typed method wrappers around GatewayClient, one per tui_gateway RPC.
//
//  Each method maps to a method name in `ProtocolCatalog.swift` (generated
//  from the OpenRPC spec) and decodes the result into the generated Codable
//  struct. The generated `GWMethod` constants use a PascalCase prefix
//  (e.g. `GWMethod.Session_create`), matching the generator's naming.
//

import Foundation
import GeneratedModels

/// Typed convenience methods for the tui_gateway JSON-RPC contract.
///
/// `HermesClient` is the high-level API surface of the iOS client. It owns
/// no socket — every call goes through the `GatewayClient` it wraps, which
/// performs JSON-RPC correlation, timeouts, and reconnect replay.
///
/// - Note: All methods are `@MainActor`-isolated because they share the
///   `GatewayClient`'s actor. Await them from SwiftUI with `await`.
@MainActor
public final class HermesClient {
    /// The underlying JSON-RPC transport.
    public let gateway: GatewayClient

    /// Create a client bound to a connected `GatewayClient`.
    /// - Parameter gateway: an open `GatewayClient` (see `GatewayClient.connect`).
    public init(gateway: GatewayClient) {
        self.gateway = gateway
    }

    // MARK: - Session lifecycle

    /// Mint a live session.
    /// - Parameters:
    ///   - profile: optional profile name to scope the session to.
    ///   - cwd: optional working directory for the session.
    ///   - source: client identifier (defaults to `"ios"`).
    /// - Returns: the created session, including its initial transcript.
    public func createSession(
        profile: String? = nil,
        cwd: String? = nil,
        source: String = "ios"
    ) async throws -> SessionCreateResult {
        var params: [String: JSONValue] = ["source": .string(source)]
        if let profile { params["profile"] = .string(profile) }
        if let cwd { params["cwd"] = .string(cwd) }
        return try await gateway.request(
            GWMethod.Session_create,
            params: .object(params)
        )
    }

    /// Attach to a stored session.
    /// - Parameters:
    ///   - sessionID: the stored session identifier.
    ///   - profile: optional profile name.
    /// - Returns: the resumed session with its transcript and live info.
    public func resumeSession(
        sessionID: String,
        profile: String? = nil
    ) async throws -> SessionResumeResult {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Session_resume,
            params: .object(params)
        )
    }

    /// Human-facing stored sessions, most recent first.
    /// - Parameter profile: optional profile name.
    /// - Returns: the list of stored session rows.
    public func listSessions(profile: String? = nil) async throws -> SessionListResult {
        var params: [String: JSONValue] = [:]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Session_list,
            params: .object(params)
        )
    }

    /// The durable display transcript (ancestors included).
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - profile: optional profile name.
    /// - Returns: the full transcript history for the session.
    public func sessionHistory(
        sessionID: String,
        profile: String? = nil
    ) async throws -> SessionHistoryResult {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Session_history,
            params: .object(params)
        )
    }

    /// Replay events after a seq watermark on WS reconnect.
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - lastSeen: the last delivered `seq` for this session.
    ///   - profile: optional profile name.
    /// - Returns: missed events, the latest seq, and truncation/epoch flags.
    public func eventsSince(
        sessionID: String,
        lastSeen: Int64,
        profile: String? = nil
    ) async throws -> SessionEventsSinceResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "last_seen": .integer(lastSeen),
        ]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Session_events_since,
            params: .object(params)
        )
    }

    // MARK: - Prompts

    /// Send a user turn to a live session.
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - text: the user's prompt text.
    ///   - profile: optional profile name.
    /// - Returns: the submit acknowledgement (status, isolation info).
    public func submitPrompt(
        sessionID: String,
        text: String,
        profile: String? = nil
    ) async throws -> PromptSubmitResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "text": .string(text),
        ]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Prompt_submit,
            params: .object(params)
        )
    }

    /// Interrupt the running turn.
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - profile: optional profile name.
    /// - Returns: the interrupt acknowledgement.
    public func interruptSession(
        sessionID: String,
        profile: String? = nil
    ) async throws -> SessionInterruptResult {
        var params: [String: JSONValue] = ["session_id": .string(sessionID)]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Session_interrupt,
            params: .object(params)
        )
    }

    // MARK: - Session management

    /// Delete a stored session.
    /// - Parameter sessionID: the session identifier.
    public func deleteSession(sessionID: String) async throws -> SessionDeleteResult {
        try await gateway.request(
            GWMethod.Session_delete,
            params: .object(["session_id": .string(sessionID)])
        )
    }

    /// Archive a stored session.
    /// - Parameter sessionID: the session identifier.
    public func archiveSession(sessionID: String) async throws -> SessionArchiveResult {
        try await gateway.request(
            GWMethod.Session_archive,
            params: .object(["session_id": .string(sessionID)])
        )
    }

    /// Fetch a session's status summary.
    /// - Parameter sessionID: the session identifier.
    public func sessionStatus(sessionID: String) async throws -> SessionStatusResult {
        try await gateway.request(
            GWMethod.Session_status,
            params: .object(["session_id": .string(sessionID)])
        )
    }

    /// Fetch a session's token/usage accounting.
    /// - Parameter sessionID: the session identifier.
    public func sessionUsage(sessionID: String) async throws -> SessionUsageResult {
        try await gateway.request(
            GWMethod.Session_usage,
            params: .object(["session_id": .string(sessionID)])
        )
    }

    // MARK: - Model picker

    /// Available model/provider options for the picker.
    /// - Parameter sessionID: optional session to scope options to.
    public func modelOptions(sessionID: String? = nil) async throws -> ModelOptionsResult {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await gateway.request(
            GWMethod.Model_options,
            params: .object(params)
        )
    }

    // MARK: - Config

    /// The resolved configuration sections.
    /// - Parameter sessionID: optional session to scope config to.
    public func configShow(sessionID: String? = nil) async throws -> ConfigShowResult {
        var params: [String: JSONValue] = [:]
        if let sessionID { params["session_id"] = .string(sessionID) }
        return try await gateway.request(
            GWMethod.Config_show,
            params: .object(params)
        )
    }

    // MARK: - Config

    /// Set a single config key for a session.
    /// - Parameters:
    ///   - sessionID: the session to scope the key to.
    ///   - key: the config key (e.g. `"model"`).
    ///   - value: the new value.
    public func configSet(
        sessionID: String,
        key: String,
        value: JSONValue
    ) async throws -> ConfigSetResult {
        try await gateway.request(
            GWMethod.Config_set,
            params: .object([
                "session_id": .string(sessionID),
                "key": .string(key),
                "value": value,
            ])
        )
    }

    // MARK: - Profiles

    /// List available profiles.
    public func listProfiles() async throws -> ProfilesListResult {
        try await gateway.request(GWMethod.Profiles_list, params: .null)
    }

    // MARK: - Attachments

    /// Stage a non-image file into the session workspace and get back its
    /// `@file:` ref text for injection into the next prompt.
    ///
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - profile: optional profile name.
    ///   - path: a gateway-visible path to the file. If nil, pass bytes via
    ///     `dataURL` (a `data:` URL).
    ///   - dataURL: a `data:` URL carrying the file bytes (alternative to
    ///     `path`).
    ///   - name: an optional display name for the file.
    /// - Returns: the attach result including `refText` to inject.
    public func attachFile(
        sessionID: String,
        profile: String? = nil,
        path: String? = nil,
        dataURL: String? = nil,
        name: String? = nil
    ) async throws -> FileAttachResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
        ]
        if let profile { params["profile"] = .string(profile) }
        if let path { params["path"] = .string(path) }
        if let dataURL { params["data_url"] = .string(dataURL) }
        if let name { params["name"] = .string(name) }
        return try await gateway.request(
            GWMethod.File_attach,
            params: .object(params)
        )
    }

    /// Stage an image from a gateway-visible path into the session.
    public func attachImage(
        sessionID: String,
        path: String,
        profile: String? = nil
    ) async throws -> AttachedImageResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "path": .string(path),
        ]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Image_attach,
            params: .object(params)
        )
    }

    /// Stage image bytes (base64) into the session.
    public func attachImageBytes(
        sessionID: String,
        contentBase64: String,
        profile: String? = nil,
        filename: String? = nil,
        ext: String? = nil
    ) async throws -> AttachedImageResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "content_base64": .string(contentBase64),
        ]
        if let profile { params["profile"] = .string(profile) }
        if let filename { params["filename"] = .string(filename) }
        if let ext { params["ext"] = .string(ext) }
        return try await gateway.request(
            GWMethod.Image_attach_bytes,
            params: .object(params)
        )
    }

    /// Detach a previously attached image.
    public func detachImage(
        sessionID: String,
        path: String,
        profile: String? = nil
    ) async throws -> ImageDetachResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "path": .string(path),
        ]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Image_detach,
            params: .object(params)
        )
    }

    /// Stage a PDF into the session workspace.
    public func attachPDF(
        sessionID: String,
        path: String,
        profile: String? = nil
    ) async throws -> PdfAttachResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "path": .string(path),
        ]
        if let profile { params["profile"] = .string(profile) }
        return try await gateway.request(
            GWMethod.Pdf_attach,
            params: .object(params)
        )
    }

    // MARK: - Approvals

    /// Tell the backend that the approval card is on screen, so its timeout
    /// clock starts.
    /// - Parameters:
    ///   - sessionID: the session the approval belongs to.
    ///   - requestID: the approval's request id.
    /// - Returns: the acknowledgement.
    public func acknowledgeApproval(
        sessionID: String,
        requestID: String
    ) async throws -> ApprovalReceivedResult {
        try await gateway.request(
            GWMethod.Approval_received,
            params: .object([
                "session_id": .string(sessionID),
                "request_id": .string(requestID),
            ])
        )
    }

    /// Answer a dangerous-command approval prompt.
    /// - Parameters:
    ///   - sessionID: the session the approval belongs to.
    ///   - choice: `once`, `session`, `always`, or `deny`.
    ///   - all: optionally apply the choice to all pending approvals.
    /// - Returns: the number of approvals resolved.
    /// - Note: The backend default approval timeout is 300s, so this call
    ///   uses a matching request timeout.
    public func respondApproval(
        sessionID: String,
        choice: ApprovalChoice,
        all: Bool? = nil
    ) async throws -> ApprovalRespondResult {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "choice": .string(choice.rawValue),
        ]
        if let all { params["all"] = .bool(all) }
        return try await gateway.request(
            GWMethod.Approval_respond,
            params: .object(params),
            timeoutMs: 300_000 // Match backend default (approvals.timeout = 300s)
        )
    }

    // MARK: - Ping

    /// Lightweight liveness probe.
    public func ping() async throws -> JSONValue {
        try await gateway.requestRaw(GWMethod.Ping, params: .null)
    }

    // MARK: - Capabilities

    /// Gateway-advertised capabilities.
    public func gatewayCapabilities() async throws -> GatewayCapabilitiesResult {
        try await gateway.request(GWMethod.Gateway_capabilities, params: .null)
    }

    /// Advertise this client's capabilities to a session.
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - source: client identifier (defaults to `"ios"`).
    public func clientCapabilities(
        sessionID: String,
        source: String = "ios"
    ) async throws -> ClientCapabilitiesResult {
        try await gateway.request(
            GWMethod.Client_capabilities,
            params: .object([
                "session_id": .string(sessionID),
                "source": .string(source),
            ])
        )
    }

    // MARK: - Slash commands

    /// Execute a slash command in a session.
    /// - Parameters:
    ///   - sessionID: the session identifier.
    ///   - command: the slash command (without leading `/`).
    public func slashExec(
        sessionID: String,
        command: String
    ) async throws -> SlashExecResult {
        try await gateway.request(
            GWMethod.Slash_exec,
            params: .object([
                "session_id": .string(sessionID),
                "command": .string(command),
            ])
        )
    }

    /// Catalog of available slash commands.
    public func commandsCatalog() async throws -> CommandsCatalogResult {
        try await gateway.request(GWMethod.Commands_catalog, params: .null)
    }
}
