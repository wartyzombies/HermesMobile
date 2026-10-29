import SwiftUI

#if canImport(UIKit)
import MobileCoreServices
import UniformTypeIdentifiers
#endif
#if canImport(PhotosUI)
import PhotosUI
#endif

import GeneratedModels

/// Composer view for drafting and sending a message to the Hermes gateway.
///
/// Supports attaching images and files, which are staged on the gateway before
/// being referenced in the submitted prompt.
struct ComposerView: View {
    @Environment(\.hermesClient) private var client

    /// Identifier of the session the composed message targets.
    let sessionID: String

    @State private var text = ""
    @State private var sending = false
    @State private var attaching = false
    @State private var showingPicker = false
    @State private var showingFileImporter = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let error = errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal).padding(.vertical, 4).transition(.opacity)
            }
            HStack(alignment: .bottom) {
                Button { showingPicker = true } label: { Image(systemName: "photo").font(.title3) }
                    .help("Attach image").accessibilityLabel("Attach image").disabled(sending || attaching)
                Button { showingFileImporter = true } label: { Image(systemName: "doc.badge.plus").font(.title3) }
                    .help("Attach file").accessibilityLabel("Attach file").disabled(sending || attaching)
                TextField("Message Hermes…", text: $text, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder).disabled(sending)
                Button { Task { await send() } } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .accessibilityLabel("Send message")
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending || attaching)
            }
            .padding()
        }
        .sheet(isPresented: $showingPicker) {
            #if canImport(UIKit) && canImport(PhotosUI)
            ImagePicker { result in
                switch result {
                case .success(let image): Task { await stageImage(image) }
                case .failure(let error): errorMessage = error.localizedDescription
                }
            }
            #endif
        }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item, .pdf, .text, .image], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await stageFile(url) } }
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Attachment staging

    #if canImport(UIKit)
    /// Stages an image attachment on the gateway for the current session.
    @MainActor
    private func stageImage(_ image: UIImage) async {
        attaching = true
        defer { attaching = false }
        do {
            let result = try await attachImageBytes(image)
            // `image.attach_bytes` queues the image for the next turn; unlike
            // `file.attach` it returns no ref text to inject into the prompt.
            if !result.attached {
                errorMessage = result.message ?? "The gateway did not attach the image"
            }
        } catch {
            errorMessage = "Failed to attach image: \(error.localizedDescription)"
        }
    }

    /// Encodes the image and uploads it via the gateway client.
    private func attachImageBytes(_ image: UIImage) async throws -> AttachedImageResult {
        let data: Data
        let ext: String
        if let png = image.pngData() { data = png; ext = "png" }
        else if let jpeg = image.jpegData(compressionQuality: 0.9) { data = jpeg; ext = "jpg" }
        else { throw NSError(domain: "ComposerView", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to encode image"]) }
        guard let client else { throw NSError(domain: "ComposerView", code: -1, userInfo: [NSLocalizedDescriptionKey: "No client"]) }
        return try await client.attachImageBytes(sessionID: sessionID, contentBase64: data.base64EncodedString(), ext: ext)
    }
    #endif

    /// Stages a file attachment on the gateway for the current session.
    @MainActor
    private func stageFile(_ url: URL) async {
        attaching = true
        defer { attaching = false }
        do {
            guard let client else { errorMessage = "No gateway client connected"; return }
            let result = try await client.attachFile(sessionID: sessionID, path: url.path, name: url.lastPathComponent)
            let ref = result.refText
            if !ref.isEmpty { insertAttachment(ref) }
        } catch {
            errorMessage = "Failed to attach file: \(error.localizedDescription)"
        }
    }

    // MARK: - Send

    /// Submits the composed prompt to the gateway and clears the input on success.
    private func send() async {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, let client else { return }
        sending = true
        defer { sending = false }
        do {
            _ = try await client.submitPrompt(sessionID: sessionID, text: prompt)
            text = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func insertAttachment(_ refText: String) {
        text = text.isEmpty ? refText : "\(text)\n\(refText)"
    }
}

#if canImport(UIKit) && canImport(PhotosUI)
/// A `UIViewControllerRepresentable` wrapping `PHPickerViewController` for image selection.
private struct ImagePicker: UIViewControllerRepresentable {
    enum PickError: Error { case noImage }
    let onSelect: (Result<UIImage, Error>) -> Void
    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }
    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: (Result<UIImage, Error>) -> Void
        init(onSelect: @escaping (Result<UIImage, Error>) -> Void) { self.onSelect = onSelect }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider else { onSelect(.failure(PickError.noImage)); return }
            provider.loadItem(forTypeIdentifier: kUTTypeImage as String, options: nil) { item, _ in
                guard let data = item as? Data, let image = UIImage(data: data) else {
                    DispatchQueue.main.async { self.onSelect(.failure(PickError.noImage)) }; return
                }
                DispatchQueue.main.async { self.onSelect(.success(image)) }
            }
        }
    }
}
#endif
""", "path": "/opt/data/profiles/coder/cache/scratch/HermesMobile/Sources/Views/Chat/ComposerView.swift"}