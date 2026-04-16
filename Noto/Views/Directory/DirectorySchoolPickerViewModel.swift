import Foundation

/// Drives the `DirectorySchoolPickerView` — owns the debounced search
/// loop, the observable state machine, and the chosen result.
///
/// The search function is injected as a closure (rather than a
/// `DirectoryAPIClient` reference) so tests can drive any scenario
/// without mocking `URLProtocol`. Production callers pass
/// `DirectoryAPIClient().searchSchools` directly.
@MainActor
@Observable
final class DirectorySchoolPickerViewModel {

    enum State: Equatable {
        case idle                                      // empty query
        case searching                                 // in-flight
        case results([DirectorySchoolSummary])         // non-empty hit list
        case empty                                     // server returned 0 matches
        case error(String)                             // network / HTTP / decode
    }

    /// Minimum characters before the debounced search fires. The server
    /// refuses `q` under 2 chars with a 400 anyway — match that here
    /// to avoid the round-trip.
    static let minQueryLength = 2

    /// Delay after the last keystroke before kicking off a request.
    /// Keeps celyn off the hot path while the parent is still typing.
    static let debounceNanoseconds: UInt64 = 300_000_000

    private(set) var state: State = .idle
    var query: String = "" {
        didSet { onQueryChange() }
    }

    private let search: @Sendable (String) async throws -> [DirectorySchoolSummary]
    private var debounceTask: Task<Void, Never>?

    init(search: @escaping @Sendable (String) async throws -> [DirectorySchoolSummary]) {
        self.search = search
    }

    // No deinit: the debounce Task uses `[weak self]`, so when the VM
    // deallocates the task becomes a no-op after its sleep. Adding a
    // `deinit { debounceTask?.cancel() }` would require hopping actors
    // from a nonisolated context — more friction than value.

    // MARK: - Actions

    /// Cancel any in-flight request and reset to idle.
    func reset() {
        debounceTask?.cancel()
        debounceTask = nil
        state = .idle
    }

    /// Run the search immediately (skip debounce). Useful for tests and
    /// for the "submit" keyboard action. No-op when the query is too short.
    func runSearchNow() async {
        debounceTask?.cancel()
        await performSearch(for: query)
    }

    // MARK: - Debounce

    private func onQueryChange() {
        debounceTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < Self.minQueryLength {
            // Below min length is idle, regardless of whatever state the
            // in-flight request was about to leave us in.
            state = .idle
            return
        }
        // Note: .searching is set INSIDE the Task after the debounce
        // sleep. Setting it here would show a spinner on every keystroke,
        // defeating the debounce's coalescing UX.
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }
            guard let self else { return }
            self.state = .searching
            await self.performSearch(for: trimmed)
        }
    }

    private func performSearch(for q: String) async {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minQueryLength else {
            state = .idle
            return
        }
        do {
            let results = try await search(trimmed)
            // Stale-response guard — by the time the request returned,
            // the user may have typed more, typed less (below min), or
            // cleared the field entirely. Sync state back to what the
            // user is actually looking at.
            let currentTrimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == currentTrimmed else {
                if currentTrimmed.count < Self.minQueryLength {
                    state = .idle
                }
                return
            }
            state = results.isEmpty ? .empty : .results(results)
        } catch {
            // Only surface the error if it's still about the current query —
            // an error from a stale request would confuse the user.
            let currentTrimmed = self.query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed == currentTrimmed else { return }
            state = .error(error.localizedDescription)
        }
    }
}
