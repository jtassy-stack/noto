import SwiftUI
import EventKit
import EventKitUI

struct RecoDetailView: View {
    let reco: CultureSearchResult
    @Environment(\.dismiss) private var dismiss

    @State private var showCalendarAlert = false
    @State private var pendingCalendarItem: CalendarItem? = nil

    private struct CalendarItem: Identifiable {
        let id = UUID()
        let event: EKEvent
        let store: EKEventStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection
                    contentSection
                        .padding(NotoTheme.Spacing.md)
                }
            }
            .ignoresSafeArea(edges: .top)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(NotoTheme.Colors.textSecondary)
                            .font(.title2)
                    }
                }
            }
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottomLeading) {
            if let urlString = reco.imageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure, .empty:
                        placeholderHero
                    @unknown default:
                        placeholderHero
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 280)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                )
            } else {
                placeholderHero
                    .frame(height: 280)
            }

            VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                typeBadge
                Text(reco.title)
                    .font(NotoTheme.Typography.title)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
            .padding(NotoTheme.Spacing.md)
        }
    }

    private var placeholderHero: some View {
        ZStack {
            NotoTheme.Colors.brand.opacity(0.12)
            Image(systemName: typeIconName)
                .font(.system(size: 60))
                .foregroundStyle(NotoTheme.Colors.brand.opacity(0.5))
        }
    }

    private var typeBadge: some View {
        Text(typeLabel)
            .font(NotoTheme.Typography.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .foregroundStyle(.white)
    }

    // MARK: - Content

    private var contentSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.lg) {
            if let desc = reco.description, !desc.isEmpty {
                descriptionSection(desc)
            }

            switch reco.type {
            case "event":
                eventSection
            case "podcast":
                podcastSection
            case "oeuvre":
                oeuvreSection
            default:
                EmptyView()
            }

            if !reco.topics.isEmpty {
                topicsSection
            }

            if let ageMin = reco.ageMin, let ageMax = reco.ageMax {
                ageSection(min: ageMin, max: ageMax)
            } else if let ageMin = reco.ageMin {
                Label("Recommandé à partir de \(ageMin) ans", systemImage: "figure.child")
                    .font(NotoTheme.Typography.caption)
                    .foregroundStyle(NotoTheme.Colors.textSecondary)
            }
        }
    }

    private func descriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            Text(text)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Event

    @ViewBuilder
    private var eventSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionHeader("Lieu & dates")

            if let venue = reco.venueName {
                infoRow(icon: "mappin.circle.fill", text: reco.venueCity.map { "\(venue), \($0)" } ?? venue)
            } else if let city = reco.venueCity {
                infoRow(icon: "mappin.circle.fill", text: city)
            }

            if let start = reco.startTime {
                infoRow(icon: "calendar", text: formatDateFR(start))
            }

            if let end = reco.endTime {
                infoRow(icon: "calendar.badge.checkmark", text: "Jusqu'au \(formatDateFR(end))")
            }

            if let oeuvreTitle = reco.oeuvreTitle {
                infoRow(icon: "theatermasks", text: oeuvreTitle)
            }

            if let venue = reco.venueName, let city = reco.venueCity {
                let query = "\(venue) \(city)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if let url = URL(string: "maps://?q=\(query)") {
                    Link(destination: url) {
                        Label("Voir sur Plans", systemImage: "map.fill")
                            .font(NotoTheme.Typography.body)
                            .fontWeight(.medium)
                            .foregroundStyle(NotoTheme.Colors.brand)
                    }
                    .padding(.top, NotoTheme.Spacing.xs)
                }
            }

            // "Ajouter à l'agenda" button
            // NOTE: NSCalendarsWriteOnlyAccessUsageDescription must be added to Info.plist
            Button {
                Task { await requestAndAddToCalendar() }
            } label: {
                Label("Ajouter à l'agenda", systemImage: "calendar.badge.plus")
                    .font(NotoTheme.Typography.body)
                    .fontWeight(.medium)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(NotoTheme.Colors.brand.opacity(0.12))
                    .foregroundStyle(NotoTheme.Colors.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(.top, NotoTheme.Spacing.xs)
            .alert("Accès calendrier refusé", isPresented: $showCalendarAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Autorisez l'accès au calendrier dans Réglages iOS pour ajouter cet événement.")
            }
            .sheet(item: $pendingCalendarItem) { item in
                EventKitAdder(event: item.event, store: item.store)
            }
        }
    }

    // MARK: - Podcast

    @ViewBuilder
    private var podcastSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionHeader("Podcast")

            if let show = reco.showName {
                infoRow(icon: "headphones", text: show)
            }

            if let station = reco.station {
                infoRow(icon: "radio", text: station)
            }

            if let episode = reco.episodeTitle {
                infoRow(icon: "play.circle", text: episode)
            }

            if let published = reco.publishedAt {
                infoRow(icon: "clock", text: "Publié le \(formatDateFR(published))")
            }

            if let summary = reco.opinionSummary, !summary.isEmpty {
                VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
                    Text("Avis")
                        .font(NotoTheme.Typography.caption)
                        .foregroundStyle(NotoTheme.Colors.textSecondary)
                    Text(summary)
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, NotoTheme.Spacing.xs)
            }

            if let audioString = reco.audioURL, let url = URL(string: audioString) {
                Link(destination: url) {
                    Label("Écouter", systemImage: "headphones")
                        .font(NotoTheme.Typography.body)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(NotoTheme.Colors.brand)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.top, NotoTheme.Spacing.xs)
            }
        }
    }

    // MARK: - Oeuvre

    @ViewBuilder
    private var oeuvreSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.sm) {
            sectionHeader("À propos")

            if let author = reco.author {
                infoRow(icon: "person.fill", text: author)
            }

            if let director = reco.director {
                infoRow(icon: "film.fill", text: "Réalisé par \(director)")
            }

            if let year = reco.year {
                infoRow(icon: "calendar", text: String(year))
            }

            if let oeuvreType = reco.oeuvreType {
                infoRow(icon: "tag.fill", text: oeuvreType.capitalized)
            }

            if !reco.genres.isEmpty {
                HStack(spacing: NotoTheme.Spacing.xs) {
                    Image(systemName: "list.bullet.indent")
                        .foregroundStyle(NotoTheme.Colors.brand)
                        .frame(width: 20)
                    Text(reco.genres.joined(separator: ", "))
                        .font(NotoTheme.Typography.body)
                        .foregroundStyle(NotoTheme.Colors.textPrimary)
                }
            }
        }
    }

    // MARK: - Topics

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: NotoTheme.Spacing.xs) {
            sectionHeader("Thèmes")
            FlowLayout(spacing: NotoTheme.Spacing.xs) {
                ForEach(reco.topics, id: \.self) { topic in
                    Text(topic)
                        .font(NotoTheme.Typography.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(NotoTheme.Colors.brand.opacity(0.1))
                        .foregroundStyle(NotoTheme.Colors.brand)
                        .clipShape(Capsule())
                }
            }
        }
    }

    private func ageSection(min: Int, max: Int) -> some View {
        Label("Recommandé pour \(min)–\(max) ans", systemImage: "figure.child")
            .font(NotoTheme.Typography.caption)
            .foregroundStyle(NotoTheme.Colors.textSecondary)
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(NotoTheme.Typography.headline)
            .foregroundStyle(NotoTheme.Colors.textPrimary)
    }

    private func infoRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: NotoTheme.Spacing.xs) {
            Image(systemName: icon)
                .foregroundStyle(NotoTheme.Colors.brand)
                .frame(width: 20)
            Text(text)
                .font(NotoTheme.Typography.body)
                .foregroundStyle(NotoTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var typeLabel: String {
        switch reco.type {
        case "podcast": "Podcast"
        case "oeuvre": "Œuvre"
        case "event": "Événement"
        default: reco.type.capitalized
        }
    }

    private var typeIconName: String {
        switch reco.type {
        case "podcast": "headphones"
        case "oeuvre": "paintpalette"
        case "event": "calendar"
        default: "star"
        }
    }

    private func formatDateFR(_ isoString: String) -> String {
        // Try ISO 8601 full datetime first
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFull.date(from: isoString) {
            return frenchFormatter(date)
        }

        let isoBasic = ISO8601DateFormatter()
        if let date = isoBasic.date(from: isoString) {
            return frenchFormatter(date)
        }

        // Try date-only "yyyy-MM-dd"
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        if let date = df.date(from: isoString) {
            return frenchFormatter(date)
        }

        return isoString
    }

    private func frenchFormatter(_ date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "fr_FR")
        df.dateStyle = .long
        df.timeStyle = .none
        return df.string(from: date)
    }

    // MARK: - Calendar

    @MainActor
    private func requestAndAddToCalendar() async {
        let store = EKEventStore()
        do {
            let granted: Bool
            if #available(iOS 17.0, *) {
                granted = try await store.requestWriteOnlyAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            guard granted else {
                showCalendarAlert = true
                return
            }
            let event = EKEvent(eventStore: store)
            event.title = reco.title
            event.notes = reco.description

            // Parse start date from startTime, or fall back to 7 days from now
            let startDate: Date = {
                if let s = reco.startTime {
                    let isoFull = ISO8601DateFormatter()
                    isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let d = isoFull.date(from: s) { return d }
                    if let d = ISO8601DateFormatter().date(from: s) { return d }
                }
                return Date.now.addingTimeInterval(7 * 24 * 3600)
            }()
            event.startDate = startDate
            event.endDate = startDate.addingTimeInterval(3600) // 1 hour duration
            event.calendar = store.defaultCalendarForNewEvents

            self.pendingCalendarItem = CalendarItem(event: event, store: store)
        } catch {
            showCalendarAlert = true
        }
    }
}

// MARK: - EventKitAdder

private struct EventKitAdder: UIViewControllerRepresentable {
    let event: EKEvent
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let vc = EKEventEditViewController()
        vc.event = event
        vc.eventStore = store
        vc.editViewDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(dismiss: dismiss) }

    class Coordinator: NSObject, EKEventEditViewDelegate {
        let dismiss: DismissAction
        init(dismiss: DismissAction) { self.dismiss = dismiss }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            dismiss()
        }
    }
}

// MARK: - FlowLayout (wrapping chips)

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(bounds.size), subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct LayoutResult {
        var size: CGSize
        var frames: [CGRect]
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                totalHeight = y
                x = 0
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            frames: frames
        )
    }
}
