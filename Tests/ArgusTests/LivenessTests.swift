import Foundation
import Testing
@testable import Argus

@Suite struct LivenessTests {

    @Test func startTimeIdentity() {
        let me = ProcessInfo.processInfo.processIdentifier
        let start = Liveness.startTime(me)
        #expect(start != nil, "startTime readable for own process")
        #expect(Liveness.isAlive(me, startedAt: start), "alive with matching start time")
        #expect(!Liveness.isAlive(me, startedAt: 12345), "pid-reuse (start mismatch) → dead")
        #expect(!Liveness.isAlive(99999, startedAt: nil), "nonexistent pid → dead")
    }

    @Test func validatedStartTimeRejectsRecycledPids() {
        let me = ProcessInfo.processInfo.processIdentifier
        #expect(Liveness.validatedStartTime(me, eventDate: .now) != nil,
                "own pid existed at a current event")
        #expect(Liveness.validatedStartTime(me, eventDate: Date(timeIntervalSince1970: 0)) == nil,
                "own pid did not exist in 1970 — start time after event = recycled")
    }
}
