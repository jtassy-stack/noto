import SwiftUI
import SwiftData

// MARK: - PhotoGridView

/// Grid of school photos (blogs + schoolbook attachments) for all children.
/// Images are loaded lazily from ENTPhotoCache (disk-backed, authenticated).
struct PhotoGridView: View {
    let children: [Child]

    @State private var activeSource: ENTPhotoSource? = nil
    @State private var selectedPhoto: SchoolPhoto? = nil
    @State private var isRefreshing = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    private var allPhotos: [SchoolPhoto] {
        children.flatMap(\.photos)
            .sorted { $0.date > $1.date }
    }

    private var filteredPhotos: [SchoolPhoto] {
        guard let source = activeSource else { return allPhotos }
        return allPhotos.filter { $0.source == source }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Source filter chips
            if allPhotos.contains(where: { $0.source == .blog }) &&
               allPhotos.contains(where: { $0.source == .schoolbook }) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NotoTheme.Spacing.sm) {
                        sourceChip(nil, label: "Tout")
                        sourceChip(.blog, label: "Blogs")
                        sourceChip(.schoolbook, label: "Carnet")
                    }
                    .padding(.horizontal, NotoTheme.Spacing.md)
                    .padding(.vertical, NotoTheme.Spacing.sm)
                }
            }

            if allPhotos.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(filteredPhotos) { photo in
                            PhotoThumbnail(photo: photo, children: children)
                                .aspectRatio(1, contentMode: .fill)
                                .clipped()
                                .onTapGesture { selectedPhoto = photo }
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedPhoto) { photo in
            PhotoDetailView(photo: photo, children: children)
        }
    }

    private func sourceChip(_ source: ENTPhotoSource?, label: String) -> some View {
        let isActive = activeSource == source
        return Button(label) { activeSource = source }
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(isActive ? NotoTheme.Colors.shadow : NotoTheme.Colors.textSecondary)
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.vertical, NotoTheme.Spacing.sm - 2)
            .background(isActive ? NotoTheme.Colors.brand : Color.clear)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(isActive ? Color.clear : NotoTheme.Colors.border, lineWidth: 1))
            .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: NotoTheme.Spacing.sm) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44))
                .foregroundStyle(NotoTheme.Colors.textSecondary.opacity(0.5))
            Text("Aucune photo")
                .font(NotoTheme.Typography.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text("Les photos des blogs et carnets de liaison apparaîtront ici après synchronisation.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.lg)
        }
    }
}

// MARK: - PhotoThumbnail

/// Single thumbnail cell — loads image lazily from ENTPhotoCache.
private struct PhotoThumbnail: View {
    let photo: SchoolPhoto
    let children: [Child]

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            Rectangle()
                .fill(NotoTheme.Colors.surface)

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
                    .tint(NotoTheme.Colors.textSecondary)
            }
        }
        .task(id: photo.entPath) {
            await loadImage()
        }
    }

    private func loadImage() async {
        guard image == nil else { return }
        guard let child = children.first(where: {
            $0.photos.contains(where: { $0.entPath == photo.entPath })
        }) else { return }

        let client = makeClient(for: child)
        guard let client else { return }

        // Login before fetching
        let credKey = "ent_credentials_\(child.entProvider?.rawValue ?? "pcn")"
        guard let credData = try? KeychainService.load(key: credKey),
              let credString = String(data: credData, encoding: .utf8) else { return }
        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let _ = try? await client.login(email: String(parts[0]), password: String(parts[1]))
        else { return }

        image = await ENTPhotoCache.shared.image(for: photo.entPath, client: client)
    }

    private func makeClient(for child: Child) -> ENTClient? {
        guard let provider = child.entProvider else { return nil }
        return ENTClient(provider: provider)
    }
}

// MARK: - PhotoDetailView

/// Fullscreen photo viewer with title + source info.
struct PhotoDetailView: View {
    let photo: SchoolPhoto
    let children: [Child]

    @State private var image: UIImage? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let img = image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle(photo.title ?? "Photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let author = photo.authorName {
                    HStack {
                        Image(systemName: photo.source == .blog ? "doc.text" : "book")
                            .foregroundStyle(.white.opacity(0.7))
                        Text(author)
                            .font(NotoTheme.Typography.caption)
                            .foregroundStyle(.white.opacity(0.8))
                        Spacer()
                        Text(photo.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                            .font(NotoTheme.Typography.dataSmall)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .padding(NotoTheme.Spacing.md)
                    .background(.ultraThinMaterial)
                }
            }
        }
        .task(id: photo.entPath) { await loadImage() }
    }

    private func loadImage() async {
        guard image == nil else { return }
        guard let child = children.first(where: {
            $0.photos.contains(where: { $0.entPath == photo.entPath })
        }) else { return }

        guard let provider = child.entProvider else { return }
        let client = ENTClient(provider: provider)

        let credKey = "ent_credentials_\(provider.rawValue)"
        guard let credData = try? KeychainService.load(key: credKey),
              let credString = String(data: credData, encoding: .utf8) else { return }
        let parts = credString.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let _ = try? await client.login(email: String(parts[0]), password: String(parts[1]))
        else { return }

        image = await ENTPhotoCache.shared.image(for: photo.entPath, client: client)
    }
}
