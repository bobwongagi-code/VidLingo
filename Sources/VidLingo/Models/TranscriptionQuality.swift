import Foundation

enum WhisperDecoderProfile: String, Codable, Sendable {
    case thaiSpecialistGreedy
    case generalBeam

    var title: String {
        switch self {
        case .thaiSpecialistGreedy:
            "泰语专用 · Greedy"
        case .generalBeam:
            "通用模型 · Beam 5"
        }
    }
}

struct WhisperSegmentCandidate: Codable, Sendable {
    let profile: WhisperDecoderProfile
    let duration: Double
    let text: String
    let meanTokenProbability: Double?
}

struct WhisperSegmentCandidates: Codable, Sendable {
    let index: Int
    let offset: Double
    let duration: Double
    let candidates: [WhisperSegmentCandidate]
}

struct TranscriptionCandidateMetrics: Codable, Sendable {
    let characterCount: Int
    let characterDensity: Double
    let thaiScriptRatio: Double
    let trigramDiversity: Double
    let meanTokenProbability: Double?
    let isRepetitionLoop: Bool
    let isValid: Bool
}

struct EvaluatedWhisperCandidate: Codable, Sendable {
    let candidate: WhisperSegmentCandidate
    let metrics: TranscriptionCandidateMetrics
}

struct EvaluatedWhisperSegment: Codable, Sendable {
    let index: Int
    let offset: Double
    let duration: Double
    let candidates: [EvaluatedWhisperCandidate]
    let selectedProfile: WhisperDecoderProfile?
    let cloudReason: String?
}

struct LocalTranscriptionAssessment: Codable, Sendable {
    let selectedText: String
    let segments: [EvaluatedWhisperSegment]
    let cloudReasons: [String]

    var shouldUseCloud: Bool {
        !cloudReasons.isEmpty
    }

    var generalReviewSegmentIndexes: [Int] {
        segments
            .filter { segment in
                segment.candidates.contains { $0.candidate.profile == .generalBeam }
            }
            .map(\.index)
    }

    var usedFullGeneralReview: Bool {
        !segments.isEmpty && segments.allSatisfy { segment in
            segment.candidates.contains { $0.candidate.profile == .thaiSpecialistGreedy }
                && segment.candidates.contains { $0.candidate.profile == .generalBeam }
        }
    }
}

struct ThaiTranscriptionDiagnostics: Codable, Sendable {
    let segmentCount: Int
    let generalReviewSegmentIndexes: [Int]
    let usedFullGeneralReview: Bool
    let cloudReasons: [String]
    let usedElevenLabs: Bool
}

struct TranscriptionPipelineOutcome: Sendable {
    let sourceText: String
    let sourceDescription: String
    let thaiDiagnostics: ThaiTranscriptionDiagnostics?
}
