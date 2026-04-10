import SwiftUI
import SwiftData

// MARK: - PhotoGridView

/// Grid of school photos grouped by child, with shimmer loading and swipe-to-browse.
struct PhotoGridView: View {
    let children: [Child]
    /// Called when the user taps the sync button.
    var onSync: (() async -> Void)? = nil
    var isSyncing: Bool = false
    var lastSyncDate: Date? = nil

    @State private var fullscreenItem: FullscreenItem? = nil

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    // Photos grouped by child, most-recently-active child first
    private var groups: [(child: Child, photos: [SchoolPhoto])] {
        children
            .compactMap { child -> (Child, [SchoolPhoto])? in
                let sorted = child.photos.sorted { $0.date > $1.date }
                return sorted.isEmpty ? nil : (child, sorted)
            }
            .sorted { a, b in (a.1.first?.date ?? .distantPast) > (b.1.first?.date ?? .distantPast) }
    }

    private var allPhotosFlat: [SchoolPhoto] {
        groups.flatMap(\.1)
    }

    var body: some View {
        Group {
            if allPhotosFlat.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.child.persistentModelID) { child, photos in
                            Section {
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(photos) { photo in
                                        PhotoThumbnail(photo: photo, children: children)
                                            .aspectRatio(1, contentMode: .fill)
                                            .clipped()
                                            .onTapGesture {
                                                let allForChild = photos
                                                let idx = allForChild.firstIndex(where: { $0.persistentModelID == photo.persistentModelID }) ?? 0
                                                fullscreenItem = FullscreenItem(photos: allForChild, startIndex: idx)
                                            }
                                    }
                                }
                            } header: {
                                childHeader(child, count: photos.count)
                            }
                        }
                    }
                    .padding(.bottom, NotoTheme.Spacing.lg)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                syncButton
            }
        }
        .fullScreenCover(item: $fullscreenItem) { item in
            PhotoBrowserView(photos: item.photos, startIndex: item.startIndex, children: children)
        }
    }

    // MARK: - Subviews

    private func childHeader(_ child: Child, count: Int) -> some View {
        HStack(spacing: NotoTheme.Spacing.sm) {
            Text(child.firstName)
                .font(NotoTheme.Typography.mono(13, weight: .bold))
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text("\(count)")
                .font(NotoTheme.Typography.mono(11))
                .foregroundStyle(NotoTheme.Colors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, NotoTheme.Spacing.md)
        .padding(.vertical, NotoTheme.Spacing.sm)
        .background(NotoTheme.Colors.background)
    }

    private var syncButton: some View {
        Button {
            Task { await onSync?() }
        } label: {
            if isSyncing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
            }
        }
        .disabled(isSyncing)
        .overlay(alignment: .bottomTrailing) {
            if let date = lastSyncDate, !isSyncing {
                Text(date.relativeShort)
                    .font(NotoTheme.Typography.mono(8))
                    .foregroundStyle(NotoTheme.Colors.textTertiary)
                    .offset(x: 4, y: 14)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: NotoTheme.Spacing.md) {
            Image(systemName: "photo.stack")
                .font(.system(size: 52))
                .foregroundStyle(NotoTheme.Colors.textTertiary)
            Text("Aucune photo pour l'instant")
                .font(NotoTheme.Typography.headline)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
            Text("Les photos partagées par les enseignants apparaîtront ici.")
                .font(NotoTheme.Typography.caption)
                .foregroundStyle(NotoTheme.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, NotoTheme.Spacing.xl)
            if let onSync {
                Button {
                    Task { await onSync() }
                } label: {
                    Label("Synchroniser", systemImage: "arrow.clockwise")
                        .font(NotoTheme.Typography.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(NotoTheme.Colors.brand)
                .disabled(isSyncing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - FullscreenItem

private struct FullscreenItem: Identifiable {
    let id = UUID()
    let photos: [SchoolPhoto]
    let startIndex: Int
}

// MARK: - PhotoThumbnail

private struct PhotoThumbnail: View {
    let photo: SchoolPhoto
    let children: [Child]

    @State private var image: UIImage? = nil

    var body: some View {
        ZStack {
            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else {
                ShimmerView()
            }
        }
        .task(id: photo.entPath) {
            await loadImage()
        }
        .contextMenu {
            if let img = image {
                Button {
                    Task { try? await ENTPhotoSaver.save(img) }
                } label: {
                    Label("Enregistrer dans Photos", systemImage: "square.and.arrow.down")
                }
                ShareLink(item: Image(uiImage: img), preview: SharePreview(photo.title ?? "Photo")) {
                    Label("Partager…", systemImage: "square.and.arrow.up")
                }
            }
        } preview: {
            if let img = image {
                Image(uiImage: img).resizable().scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
            } else {
                ShimmerView().frame(width: 200, height: 200)
            }
        }
    }

    private func loadImage() async {
        guard image == nil else { return }
        guard let child = children.first(where: {
            $0.photos.contains(where: { $0.entPath == photo.entPath })
        }) else { return }
        guard let provider = child.entProvider else { return }
        let client = ENTClient(provider: provider)
        let loaded = await ENTPhotoCache.shared.image(for: photo.entPath, client: client)
        if let loaded {
            withAnimation { image = loaded }
        }
    }
}

// MARK: - PhotoBrowserView

/// Full-screen swipeable photo viewer (Instagram / iOS Photos style).
struct PhotoBrowserView: View {
    let photos: [SchoolPhoto]
    let startIndex: Int
    let children: [Child]

    @State private var currentIndex: Int
    @Environment(\.dismiss) private var dismiss

    init(photos: [SchoolPhoto], startIndex: Int, children: [Child]) {
        self.photos = photos
        self.startIndex = startIndex
        self.children = children
        _currentIndex = State(initialValue: startIndex)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(photos.enumerated()), id: \.element.persistentModelID) { idx, photo in
                    PhotoPageView(photo: photo, children: children)
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()

            // Top bar
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.black.opacity(0.4))
                        .clipShape(Circle())
                }
                Spacer()
                Text("\(currentIndex + 1) / \(photos.count)")
                    .font(NotoTheme.Typography.mono(13))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .padding(.horizontal, NotoTheme.Spacing.md)
            .padding(.top, 56)
        }
    }
}

// MARK: - PhotoPageView

private struct PhotoPageView: View {
    let photo: SchoolPhoto
    let children: [Child]

    @State private var image: UIImage? = nil
    @State private var saveToast: String? = nil

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let img = image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeIn(duration: 0.15)))
            } else {
                ShimmerView()
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: NotoTheme.Radius.md))
            }

            // Toast
            if let toast = saveToast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, NotoTheme.Spacing.md)
                        .padding(.vertical, NotoTheme.Spacing.sm)
                        .background(.black.opacity(0.7))
                        .clipShape(Capsule())
                        .padding(.bottom, 100)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            photoInfo
        }
        .toolbar {
            if let img = image {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { Task { await save(img) } } label: {
                        Image(systemName: "square.and.arrow.down").foregroundStyle(.white)
                    }
                    ShareLink(item: Image(uiImage: img), preview: SharePreview(photo.title ?? "Photo")) {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(.white)
                    }
                }
            }
        }
        .task(id: photo.entPath) { await loadImage() }
    }

    @ViewBuilder
    private var photoInfo: some View {
        if photo.title != nil || photo.authorName != nil {
            HStack(spacing: NotoTheme.Spacing.sm) {
                Image(systemName: photo.source == .blog ? "doc.richtext" : "book.closed")
                    .foregroundStyle(.white.opacity(0.6))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 2) {
                    if let title = photo.title {
                        Text(title)
                            .font(NotoTheme.Typography.mono(12, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    if let author = photo.authorName {
                        Text(author)
                            .font(NotoTheme.Typography.mono(11))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
                Text(photo.date.formatted(.dateTime.day().month(.abbreviated).locale(Locale(identifier: "fr_FR"))))
                    .font(NotoTheme.Typography.mono(11))
                    .foregroundStyle(.white.opacity(0.6))

                if let img = image {
                    ShareLink(item: Image(uiImage: img), preview: SharePreview(photo.title ?? "Photo")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    Button { Task { await save(img) } } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
            }
            .padding(NotoTheme.Spacing.md)
            .background(.ultraThinMaterial.opacity(0.85))
        }
    }

    private func loadImage() async {
        guard image == nil else { return }
        guard let child = children.first(where: {
            $0.photos.contains(where: { $0.entPath == photo.entPath })
        }) else { return }
        guard let provider = child.entProvider else { return }
        let client = ENTClient(provider: provider)
        if let loaded = await ENTPhotoCache.shared.image(for: photo.entPath, client: client) {
            withAnimation { image = loaded }
        }
    }

    private func save(_ img: UIImage) async {
        do {
            try await ENTPhotoSaver.save(img)
            withAnimation { saveToast = "Enregistrée ✓" }
        } catch {
            withAnimation { saveToast = "Erreur — vérifiez les autorisations Photos" }
        }
        try? await Task.sleep(for: .seconds(2))
        withAnimation { saveToast = nil }
    }
}

// MARK: - Date helper

private extension Date {
    var relativeShort: String {
        let diff = Date.now.timeIntervalSince(self)
        if diff < 60 { return "à l'instant" }
        if diff < 3600 { return "\(Int(diff / 60))min" }
        if diff < 86400 { return "\(Int(diff / 3600))h" }
        return "\(Int(diff / 86400))j"
    }
}

#Preview("Photos — vide") {
    PhotoGridView(children: [])
}
