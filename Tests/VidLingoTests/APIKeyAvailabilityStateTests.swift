import XCTest
@testable import VidLingo

final class APIKeyAvailabilityStateTests: XCTestCase {
    func testServiceRefreshClearsPreviousConfiguredState() {
        var state = APIKeyAvailabilityState()
        state.set(.configured)
        let revision = state.beginRefresh(reset: true)
        XCTAssertEqual(state.value, .missing)
        state.apply(.configured, revision: revision)
        XCTAssertEqual(state.value, .configured)
    }

    func testSavedKeyRejectsEarlierMissingResult() {
        var state = APIKeyAvailabilityState()
        let revision = state.beginRefresh(reset: false)
        state.set(.configured)
        state.apply(.missing, revision: revision)
        XCTAssertEqual(state.value, .configured)
    }

    func testDeletedKeyRejectsEarlierConfiguredResult() {
        var state = APIKeyAvailabilityState()
        state.set(.configured)
        let revision = state.beginRefresh(reset: false)
        state.set(.missing)
        state.apply(.configured, revision: revision)
        XCTAssertEqual(state.value, .missing)
    }

    func testNewRefreshRejectsEarlierRefreshResult() {
        var state = APIKeyAvailabilityState()
        let oldRevision = state.beginRefresh(reset: true)
        let newRevision = state.beginRefresh(reset: true)
        state.apply(.missing, revision: newRevision)
        state.apply(.configured, revision: oldRevision)
        XCTAssertEqual(state.value, .missing)
    }

    func testTranslationMutationDoesNotDiscardASRRefresh() {
        var translation = APIKeyAvailabilityState()
        var asr = APIKeyAvailabilityState()
        let translationRevision = translation.beginRefresh(reset: true)
        let asrRevision = asr.beginRefresh(reset: false)
        translation.set(.configured)
        translation.apply(.missing, revision: translationRevision)
        asr.apply(.configured, revision: asrRevision)
        XCTAssertEqual(translation.value, .configured)
        XCTAssertEqual(asr.value, .configured)
    }
}
