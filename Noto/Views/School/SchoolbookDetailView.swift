import SwiftUI
import WebKit

// MARK: - SchoolbookDetailView

struct SchoolbookDetailView: View {
    let child: Child
    let msg: Message

    @Environment(\.dismiss) private var dismiss
    @State private var processedHTML: String? = nil
    @State private var attachments: [SchoolbookAttachment] = []
    @State private var isLoading = true
    @State private var loadError: String? = nil
    @State private var acknowledged: Bool
    @State private var isSigning = false
    @State private var shareItem: SchoolbookShareItem? = nil

    init(child: Child, msg: Message) {
        self.child = child
        self.msg = msg
        _acknowledged = State(initialValue: msg.read)
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Header
                    VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                        Text(msg.subject)
                            .font(NotoTheme.Typography.title)
                            .foregroundStyle(NotoTheme.Colors.textPrimary)

                        HStack {
                            Label(msg.sender, systemImage: "person")
                            Spacer()
                            Text(msg.date.formatted(
                                .dateTime.day().month(.abbreviated).year()
                                .locale(Locale(identifier: "fr_FR"))
                            ))
                        }
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.top, NotoTheme.Spacing.md)
                    .padding(.bottom, NotoTheme.Spacing.sm)

                    // Attachments
                    if !attachments.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: NotoTheme.Spacing.sm) {
                                ForEach(attachments) { attachment in
                                    Button {
                                        Task { await downloadAttachment(attachment) }
                                    } label: {
                                        Label(attachment.name, systemImage: "paperclip")
                                            .font(NotoTheme.Typography.caption)
                                            .foregroundStyle(NotoTheme.Colors.textPrimary)
                                            .padding(.horizontal, NotoTheme.Spacing.sm)
                                            .padding(.vertical, NotoTheme.Spacing.xs)
                                            .background(NotoTheme.Colors.surface)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, NotoTheme.Spacing.md)
                            .padding(.vertical, NotoTheme.Spacing.xs)
                        }
                    }

                    Divider()

                    // Content
                    if isLoading {
                        Spacer()
                        ProgressView()
                            .tint(NotoTheme.Colors.brand)
                        Spacer()
                    } else if let error = loadError {
                        Spacer()
                        VStack(spacing: NotoTheme.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                            Text(error)
                                .font(NotoTheme.Typography.body)
                                .foregroundStyle(NotoTheme.Colors.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(NotoTheme.Spacing.lg)
                        Spacer()
                    } else if let html = processedHTML {
                        SchoolbookWebView(html: html)
                    }

                    // Bottom padding for sign button
                    if !acknowledged {
                        Color.clear.frame(height: 80)
                    }
                }

                // Sign button
                if !acknowledged {
                    VStack(spacing: 0) {
                        Spacer()
                        Button {
                            Task { await acknowledge() }
                        } label: {
                            HStack {
                                if isSigning {
                                    ProgressView()
                                        .tint(NotoTheme.Colors.shadow)
                                } else {
                                    Label("Signer", systemImage: "signature")
                                }
                            }
                            .font(NotoTheme.Typography.headline)
                            .foregroundStyle(NotoTheme.Colors.shadow)
                            .frame(maxWidth: .infinity)
                            .padding(NotoTheme.Spacing.md)
                            .background(NotoTheme.Colors.amber)
                            .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
                            .padding(.horizontal, NotoTheme.Spacing.md)
                            .padding(.bottom, NotoTheme.Spacing.md)
                        }
                        .disabled(isSigning)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .background(NotoTheme.Colors.background)
            .navigationTitle("Carnet de liaison")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
            .sheet(item: $shareItem) { item in
                ActivityView(items: [item.url])
            }
        }
        .task { await loadContent() }
    }

    // MARK: - Load Content

    @MainActor
    private func loadContent() async {
        isLoading = true
        loadError = nil

        let credKey = "ent_credentials_\(child.entProvider?.rawValue ?? "pcn")"
        guard let credData = try? KeychainService.load(key: credKey),
              let credString = String(data: credData, encoding: .utf8) else {
            loadError = "Identifiants ENT introuvables"
            isLoading = false
            return
        }

        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            loadError = "Format d'identifiants invalide"
            isLoading = false
            return
        }
        let email = String(parts[0])
        let password = String(parts[1])

        let client = ENTClient(provider: child.entProvider ?? .pcn)

        do {
            try await client.login(email: email, password: password)
        } catch {
            loadError = "Connexion ENT échouée: \(error.localizedDescription)"
            isLoading = false
            return
        }

        let rawHTML = msg.body
        var html = rawHTML
        var foundAttachments: [SchoolbookAttachment] = []

        // Process images: replace /workspace/document/... src with base64
        let imgPattern = #"src="(/workspace/document/[^"]+)""#
        if let regex = try? NSRegularExpression(pattern: imgPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
            // Process in reverse to preserve string indices
            for match in matches.reversed() {
                guard let pathRange = Range(match.range(at: 1), in: html) else { continue }
                let path = String(html[pathRange])
                if let data = try? await client.fetchData(path: path) {
                    let mime = mimeType(for: path)
                    let b64 = data.base64EncodedString()
                    let replacement = #"src="data:\#(mime);base64,\#(b64)""#
                    if let fullRange = Range(match.range, in: html) {
                        html.replaceSubrange(fullRange, with: replacement)
                    }
                }
            }
        }

        // Process attachment links: /workspace/document/... hrefs
        let linkPattern = #"href="(/workspace/document/[^"]+)""#
        if let regex = try? NSRegularExpression(pattern: linkPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: rawHTML, range: NSRange(rawHTML.startIndex..., in: rawHTML))
            for match in matches {
                guard let pathRange = Range(match.range(at: 1), in: rawHTML) else { continue }
                let path = String(rawHTML[pathRange])
                let filename = await client.fetchFilename(path: path) ?? filenameFallback(path: path)
                let fullURL = URL(string: "\(client.baseURL.absoluteString)\(path)")
                if let url = fullURL {
                    foundAttachments.append(SchoolbookAttachment(id: path, url: url, name: filename))
                }
            }
        }

        attachments = foundAttachments

        // Wrap in full HTML document
        let wrappedHTML = """
        <!DOCTYPE html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.6;
                 color: #FFFFFF; background: transparent; padding: 16px; margin: 0; }
          img { max-width: 100%; height: auto; border-radius: 8px; margin: 8px 0; }
          a { color: #34C759; }
          p { margin: 8px 0; }
        </style>
        </head><body>\(html)</body></html>
        """
        processedHTML = wrappedHTML
        isLoading = false
    }

    // MARK: - Acknowledge

    @MainActor
    private func acknowledge() async {
        guard let wordId = msg.link else { return }
        isSigning = true

        let credKey = "ent_credentials_\(child.entProvider?.rawValue ?? "pcn")"
        guard let credData = try? KeychainService.load(key: credKey),
              let credString = String(data: credData, encoding: .utf8) else {
            isSigning = false
            return
        }
        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { isSigning = false; return }

        let client = ENTClient(provider: child.entProvider ?? .pcn)
        do {
            try await client.login(email: String(parts[0]), password: String(parts[1]))
            try await client.acknowledgeSchoolbookWord(id: wordId)
            msg.read = true
            acknowledged = true
        } catch {
            // Silently fail — don't crash the view
        }
        isSigning = false
    }

    // MARK: - Attachment Download

    @MainActor
    private func downloadAttachment(_ attachment: SchoolbookAttachment) async {
        let credKey = "ent_credentials_\(child.entProvider?.rawValue ?? "pcn")"
        guard let credData = try? KeychainService.load(key: credKey),
              let credString = String(data: credData, encoding: .utf8) else { return }
        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }

        let client = ENTClient(provider: child.entProvider ?? .pcn)
        do {
            try await client.login(email: String(parts[0]), password: String(parts[1]))
            let data = try await client.fetchData(path: attachment.url.absoluteString)
            // Write to temp file
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(attachment.name)
            try data.write(to: tmpURL)
            shareItem = SchoolbookShareItem(id: attachment.id, url: tmpURL)
        } catch {
            // Ignore download errors silently
        }
    }

    // MARK: - Helpers

    private func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        default: return "image/jpeg"
        }
    }

    private func filenameFallback(path: String) -> String {
        URL(string: path)?.lastPathComponent ?? "document"
    }
}

// MARK: - Supporting Types

struct SchoolbookAttachment: Identifiable {
    let id: String
    let url: URL
    let name: String
}

struct SchoolbookShareItem: Identifiable {
    let id: String
    let url: URL
}

// MARK: - WKWebView Wrapper

struct SchoolbookWebView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}

// MARK: - UIActivityViewController Wrapper

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
