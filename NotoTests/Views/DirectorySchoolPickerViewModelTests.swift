import Testing
import Foundation
@testable import Noto

/// Coverage for `DirectorySchoolPickerViewModel`. Tests inject the
/// search closure directly — no URLProtocol mocking needed. Where
/// timing matters (debounce, stale guard), tests drive the real
/// `didSet` path and wait out `Self.debounceNanoseconds + slack`.
@Suite("DirectorySchoolPickerViewModel")
@MainActor
struct DirectorySchoolPickerViewModelTests {

    /// Debounce window plus generous CI slack. Kept centralised so a
    /// future tuning of `debounceNanoseconds` only changes one constant.
    private static let debounceSleepNs: UInt64 = DirectorySchoolPickerViewModel.debounceNanoseconds + 150_000_000

    /// `nonisolated` so `@Sendable` closures captured by the VM can call it
    /// without hopping back to the main actor.
    nonisolated private func summary(_ rne: String, _ name: String) -> DirectorySchoolSummary {
        DirectorySchoolSummary(rne: rne, name: name, kind: "college", communeInsee: nil, academy: nil)
    }

    // MARK: - Below-min-length guard

    @Test("Empty query stays idle")
    func emptyQueryStaysIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in [] }
        vm.query = ""
        #expect(vm.state == .idle)
    }

    @Test("Single-character query stays idle and does NOT call search")
    func singleCharNeverCallsSearch() async {
        let counter = CallCounter()
        let vm = DirectorySchoolPickerViewModel { _ in
            await counter.inc()
            return []
        }
        vm.query = "J"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        #expect(vm.state == .idle)
        let calls = await counter.value
        #expect(calls == 0)
    }

    @Test("Whitespace-only query stays idle")
    func whitespaceStaysIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in [] }
        vm.query = "   "
        #expect(vm.state == .idle)
    }

    // MARK: - Happy path via debounce

    @Test("Typing a query → waits debounce → .results with the hits")
    func debouncedSearchHits() async {
        let vm = DirectorySchoolPickerViewModel { q in
            [self.summary("0930122Y", "Collège Jean Jaurès (\(q))")]
        }
        vm.query = "Jaurès"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        if case .results(let schools) = vm.state {
            #expect(schools.count == 1)
            #expect(schools[0].rne == "0930122Y")
        } else {
            Issue.record("expected .results, got \(vm.state)")
        }
    }

    @Test("Empty server response → .empty state")
    func emptyResultsMapsToEmptyState() async {
        let vm = DirectorySchoolPickerViewModel { _ in [] }
        vm.query = "Unknown school name"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        #expect(vm.state == .empty)
    }

    // MARK: - Debounce coalescing

    @Test("Rapid keystrokes coalesce into a single search call")
    func debounceCoalesces() async {
        let counter = CallCounter()
        let vm = DirectorySchoolPickerViewModel { _ in
            await counter.inc()
            return []
        }
        vm.query = "J"        // below min — doesn't schedule
        vm.query = "Ja"       // schedules task #1
        vm.query = "Jau"      // cancels #1, schedules #2
        vm.query = "Jaur"     // cancels #2, schedules #3
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        let calls = await counter.value
        #expect(calls == 1)
    }

    // MARK: - Bailout when query drops below min

    @Test("Deleting back below min length during in-flight request → .idle (not stuck .searching)")
    func bailoutResetsToIdle() async {
        // Mock sleeps long enough that we can clear the query mid-flight.
        let vm = DirectorySchoolPickerViewModel { _ in
            try? await Task.sleep(nanoseconds: 100_000_000)
            return [self.summary("X", "should-be-ignored")]
        }
        vm.query = "Jaurès"
        // Wait for the debounce to fire the request but NOT long enough
        // for it to come back.
        try? await Task.sleep(nanoseconds: DirectorySchoolPickerViewModel.debounceNanoseconds + 30_000_000)
        vm.query = ""  // user hit backspace back to empty
        try? await Task.sleep(nanoseconds: 150_000_000)  // let the stale response land
        #expect(vm.state == .idle)
    }

    // MARK: - Errors

    @Test("Thrown error → .error state carries message")
    func errorPropagates() async {
        let vm = DirectorySchoolPickerViewModel { _ in
            throw DirectoryAPIError.httpError(500, "db down")
        }
        vm.query = "anywhere"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        if case .error(let message) = vm.state {
            #expect(message.contains("500"))
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    @Test("Error state clears when a subsequent query succeeds")
    func errorClearsOnNextSearch() async {
        let script = ScriptedSearch(steps: [
            .failure(DirectoryAPIError.httpError(500, nil)),
            .success([summary("R1", "Recovered")]),
        ])
        let vm = DirectorySchoolPickerViewModel(search: script.search)
        vm.query = "flaky"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        let wasError: Bool = {
            if case .error = vm.state { return true }
            return false
        }()
        #expect(wasError)
        vm.query = "stable"
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        if case .results(let schools) = vm.state {
            #expect(schools.first?.rne == "R1")
        } else {
            Issue.record("expected .results after recovery, got \(vm.state)")
        }
    }

    // MARK: - Stale response

    @Test("Stale response — latest query wins, not the older one")
    func staleResponseIgnored() async {
        // Each call sleeps 120ms. If we fire "first" then "second" in
        // rapid succession, the "second" response must be the one on
        // screen — without the stale guard an earlier response could
        // overwrite the later state.
        let vm = DirectorySchoolPickerViewModel { q in
            try? await Task.sleep(nanoseconds: 120_000_000)
            return [DirectorySchoolSummary(rne: q, name: q, kind: nil, communeInsee: nil, academy: nil)]
        }
        vm.query = "first"
        try? await Task.sleep(nanoseconds: DirectorySchoolPickerViewModel.debounceNanoseconds + 10_000_000)
        vm.query = "second"  // kicks off a new debounce while "first" is still in flight
        // Wait for both flights to settle: debounce + both 120ms calls + slack.
        try? await Task.sleep(nanoseconds: 500_000_000)
        if case .results(let schools) = vm.state {
            #expect(schools.first?.rne == "second")
        } else {
            Issue.record("expected .results for 'second', got \(vm.state)")
        }
    }

    // MARK: - Reset

    @Test("reset() returns state to idle")
    func resetToIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in [self.summary("X", "Y")] }
        vm.query = "Hugo"  // ≥ minQueryLength so the search actually fires
        try? await Task.sleep(nanoseconds: Self.debounceSleepNs)
        #expect(vm.state != .idle)
        vm.reset()
        #expect(vm.state == .idle)
    }
}

// MARK: - Test doubles

/// Thread-safe counter used to assert search-call counts.
private actor CallCounter {
    private(set) var value: Int = 0
    func inc() { value += 1 }
}

/// Sequential script — pulls one outcome per call, in order. Used to
/// verify state transitions across successive searches (error → success).
private actor ScriptedSearch {
    enum Step {
        case success([DirectorySchoolSummary])
        case failure(Error)
    }

    private var steps: [Step]

    init(steps: [Step]) { self.steps = steps }

    func next() throws -> [DirectorySchoolSummary] {
        guard !steps.isEmpty else { return [] }
        let step = steps.removeFirst()
        switch step {
        case .success(let rows): return rows
        case .failure(let err):  throw err
        }
    }

    nonisolated var search: @Sendable (String) async throws -> [DirectorySchoolSummary] {
        { [self] _ in try await self.next() }
    }
}
