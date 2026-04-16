import Testing
@testable import Noto

/// Pins the four input combinations for `ENTSyncGate.decide`. The
/// load-bearing invariant is the "empty + no-error" case: PCN
/// occasionally returns 200 OK with empty lists when the session
/// cookie has silently gone stale. Without the preserve branch, the
/// caller wipes local messages + homework and inserts nothing — the
/// user sees their data disappear. Caught by user report 2026-04-17
/// ("sync breaks").
@Suite("ENTSyncGate")
struct ENTSyncGateTests {

    @Test("hasData=true, no errors → .proceed")
    func freshDataProceeds() {
        #expect(ENTSyncGate.decide(hasData: true, fetchErrors: []) == .proceed)
    }

    @Test("hasData=true with partial errors → .proceed (partial success)")
    func partialSuccessProceeds() {
        #expect(ENTSyncGate.decide(hasData: true, fetchErrors: ["photos: timeout"]) == .proceed)
    }

    @Test("hasData=false, no errors → .preserve (do not wipe local state)")
    func emptyPayloadPreserves() {
        // The regression guard. Before the fix, this path proceeded to
        // the wipe-and-insert block.
        #expect(ENTSyncGate.decide(hasData: false, fetchErrors: []) == .preserve)
    }

    @Test("hasData=false with errors → .fail with joined detail")
    func emptyWithErrorsFails() {
        let decision = ENTSyncGate.decide(hasData: false, fetchErrors: ["messages: 500", "devoirs: 500"])
        #expect(decision == .fail("messages: 500, devoirs: 500"))
    }
}
