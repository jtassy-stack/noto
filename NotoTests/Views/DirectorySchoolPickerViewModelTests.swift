import Testing
import Foundation
@testable import Noto

/// Coverage for `DirectorySchoolPickerViewModel` — the state machine
/// behind the onboarding / Settings school picker. Every test injects
/// a mock `search` closure so we can exercise debounce, cancellation,
/// empty results, and error propagation without the network.
@Suite("DirectorySchoolPickerViewModel")
@MainActor
struct DirectorySchoolPickerViewModelTests {

    private func summary(_ rne: String, _ name: String) -> DirectorySchoolSummary {
        DirectorySchoolSummary(rne: rne, name: name, kind: "college", communeInsee: nil, academy: nil)
    }

    // MARK: - Idle / min-length

    @Test("Empty query stays idle")
    func emptyQueryStaysIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in [] }
        vm.query = ""
        #expect(vm.state == .idle)
    }

    @Test("Single-character query stays idle (below minQueryLength)")
    func singleCharStaysIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in
            Issue.record("search should not fire below min length")
            return []
        }
        vm.query = "J"
        #expect(vm.state == .idle)
    }

    @Test("Whitespace-only query stays idle")
    func whitespaceStaysIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in
            Issue.record("search should not fire on whitespace")
            return []
        }
        vm.query = "   "
        #expect(vm.state == .idle)
    }

    // MARK: - Results & empty

    @Test("runSearchNow with results → .results state")
    func runSearchNowResults() async {
        let vm = DirectorySchoolPickerViewModel { _ in
            [self.summary("0930122Y", "Collège Jean Jaurès")]
        }
        vm.query = "Jaurès"
        await vm.runSearchNow()
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
        await vm.runSearchNow()
        #expect(vm.state == .empty)
    }

    // MARK: - Errors

    @Test("Thrown error → .error state carries message")
    func errorPropagates() async {
        let vm = DirectorySchoolPickerViewModel { _ in
            throw DirectoryAPIError.httpError(500, "db down")
        }
        vm.query = "anywhere"
        await vm.runSearchNow()
        if case .error(let message) = vm.state {
            #expect(message.contains("500"))
        } else {
            Issue.record("expected .error, got \(vm.state)")
        }
    }

    // MARK: - Stale response guard

    @Test("Stale result (query changed during flight) is ignored")
    func staleResultsDropped() async {
        // Mock that takes time — lets us mutate `query` before it completes.
        let vm = DirectorySchoolPickerViewModel { q in
            try? await Task.sleep(nanoseconds: 50_000_000)
            return [DirectorySchoolSummary(rne: "X", name: "Match \(q)", kind: nil, communeInsee: nil, academy: nil)]
        }
        vm.query = "first"
        let pending = Task { await vm.runSearchNow() }
        vm.query = "second"  // user kept typing
        await pending.value
        // The in-flight response for "first" should have been ignored —
        // the VM should not be showing stale results.
        if case .results(let schools) = vm.state {
            // Whatever state we land in, it must NOT be the stale "first" match.
            #expect(!schools.contains { $0.name.contains("first") })
        }
    }

    // MARK: - Reset

    @Test("reset() returns state to idle")
    func resetToIdle() async {
        let vm = DirectorySchoolPickerViewModel { _ in [self.summary("X", "Y")] }
        vm.query = "Y"
        await vm.runSearchNow()
        #expect(vm.state != .idle)
        vm.reset()
        #expect(vm.state == .idle)
    }
}
