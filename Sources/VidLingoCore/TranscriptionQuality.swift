import Foundation

public enum WhisperDecoderProfile: String, Codable, Sendable {
    case thaiSpecialistGreedy
    case generalBeam

    public var title: String {
        switch self {
        case .thaiSpecialistGreedy:
            "泰语专用 · Greedy"
        case .generalBeam:
            "通用模型 · Beam 5"
        }
    }
}

public struct WhisperSegmentCandidate: Codable, Sendable {
    public let profile: WhisperDecoderProfile
    public let duration: Double
    public let text: String
    public let meanTokenProbability: Double?

    public init(profile: WhisperDecoderProfile, duration: Double, text: String, meanTokenProbability: Double?) {
        self.profile = profile
        self.duration = duration
        self.text = text
        self.meanTokenProbability = meanTokenProbability
    }
}

public struct WhisperSegmentCandidates: Codable, Sendable {
    public let index: Int
    public let offset: Double
    public let duration: Double
    public let candidates: [WhisperSegmentCandidate]

    public init(index: Int, offset: Double, duration: Double, candidates: [WhisperSegmentCandidate]) {
        self.index = index
        self.offset = offset
        self.duration = duration
        self.candidates = candidates
    }
}

public struct TranscriptionCandidateMetrics: Codable, Sendable {
    public let characterCount: Int
    public let characterDensity: Double
    public let thaiScriptRatio: Double
    public let trigramDiversity: Double
    public let meanTokenProbability: Double?
    public let tokenProbabilityAvailable: Bool
    public let isRepetitionLoop: Bool
    public let isValid: Bool

    public init(
        characterCount: Int,
        characterDensity: Double,
        thaiScriptRatio: Double,
        trigramDiversity: Double,
        meanTokenProbability: Double?,
        tokenProbabilityAvailable: Bool,
        isRepetitionLoop: Bool,
        isValid: Bool
    ) {
        self.characterCount = characterCount
        self.characterDensity = characterDensity
        self.thaiScriptRatio = thaiScriptRatio
        self.trigramDiversity = trigramDiversity
        self.meanTokenProbability = meanTokenProbability
        self.tokenProbabilityAvailable = tokenProbabilityAvailable
        self.isRepetitionLoop = isRepetitionLoop
        self.isValid = isValid
    }
}

public struct EvaluatedWhisperCandidate: Codable, Sendable {
    public let candidate: WhisperSegmentCandidate
    public let metrics: TranscriptionCandidateMetrics

    public init(candidate: WhisperSegmentCandidate, metrics: TranscriptionCandidateMetrics) {
        self.candidate = candidate
        self.metrics = metrics
    }
}

public struct EvaluatedWhisperSegment: Codable, Sendable {
    public let index: Int
    public let offset: Double
    public let duration: Double
    public let candidates: [EvaluatedWhisperCandidate]
    public let selectedProfile: WhisperDecoderProfile?
    public let cloudReason: String?

    public init(
        index: Int,
        offset: Double,
        duration: Double,
        candidates: [EvaluatedWhisperCandidate],
        selectedProfile: WhisperDecoderProfile?,
        cloudReason: String?
    ) {
        self.index = index
        self.offset = offset
        self.duration = duration
        self.candidates = candidates
        self.selectedProfile = selectedProfile
        self.cloudReason = cloudReason
    }
}

public struct LocalTranscriptionAssessment: Codable, Sendable {
    public let selectedText: String
    public let segments: [EvaluatedWhisperSegment]
    public let cloudReasons: [String]

    public init(selectedText: String, segments: [EvaluatedWhisperSegment], cloudReasons: [String]) {
        self.selectedText = selectedText
        self.segments = segments
        self.cloudReasons = cloudReasons
    }

    public var shouldUseCloud: Bool {
        !cloudReasons.isEmpty
    }

    public var generalReviewSegmentIndexes: [Int] {
        segments
            .filter { segment in
                segment.candidates.contains { $0.candidate.profile == .generalBeam }
            }
            .map(\.index)
    }

    public var usedFullGeneralReview: Bool {
        !segments.isEmpty && segments.allSatisfy { segment in
            segment.candidates.contains { $0.candidate.profile == .thaiSpecialistGreedy }
                && segment.candidates.contains { $0.candidate.profile == .generalBeam }
        }
    }
}

public struct ThaiTranscriptionDiagnostics: Codable, Sendable {
    public let qualityPolicyVersion: String
    public let segmentCount: Int
    public let generalReviewSegmentIndexes: [Int]
    public let usedFullGeneralReview: Bool
    public let cloudReasons: [String]
    public let usedElevenLabs: Bool

    public init(
        qualityPolicyVersion: String,
        segmentCount: Int,
        generalReviewSegmentIndexes: [Int],
        usedFullGeneralReview: Bool,
        cloudReasons: [String],
        usedElevenLabs: Bool
    ) {
        self.qualityPolicyVersion = qualityPolicyVersion
        self.segmentCount = segmentCount
        self.generalReviewSegmentIndexes = generalReviewSegmentIndexes
        self.usedFullGeneralReview = usedFullGeneralReview
        self.cloudReasons = cloudReasons
        self.usedElevenLabs = usedElevenLabs
    }
}
