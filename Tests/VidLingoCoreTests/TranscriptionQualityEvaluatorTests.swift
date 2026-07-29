import XCTest
@testable import VidLingoCore

final class TranscriptionQualityEvaluatorTests: XCTestCase {
    func testMissingTokenProbabilityIsReviewedSeparately() {
        let segment = WhisperSegmentCandidates(
            index: 0,
            offset: 0,
            duration: 8,
            candidates: [WhisperSegmentCandidate(
                profile: .thaiSpecialistGreedy,
                duration: 8,
                text: "ติดกระเบื้องไว้แข็งแรงทนทานจริงครับ ใช้งานได้ดีครับ",
                meanTokenProbability: nil
            )]
        )

        XCTAssertEqual(TranscriptionQualityEvaluator.generalReviewIndexes(for: [segment]), [0])
    }

    func testQualityPolicyVersionIsExplicit() {
        XCTAssertEqual(TranscriptionQualityEvaluator.policyVersion, "thai-quality-v2")
    }
}
