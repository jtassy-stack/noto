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
            state = .idle
            return
        }
        state = .searching
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            if Task.isCancelled { return }
            await self?.performSearch(for: trimmed)
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
            // Another keystroke may have arrived — bail if our query
            // no longer matches what the user is looking at.
            guard trimmed == self.query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            state = results.isEmpty ? .empty : .results(results)
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
