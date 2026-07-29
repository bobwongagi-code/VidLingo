import Foundation

public enum TranscriptionQualityEvaluator {
    public static let policyVersion = "thai-quality-v2"

    private enum Thresholds {
        // 这些阈值集中管理，配合 diagnostics 中的候选指标做后续实测校准。
        static let minimumCharacters = 12
        static let minimumThaiRatio = 0.80
        static let minimumCharacterDensity = 2.0
        static let minimumTokenProbability = 0.55
        static let reviewThaiRatio = 0.92
        static let reviewCharacterDensity = 3.0
        static let reviewTrigramDiversity = 0.42
        static let reviewTokenProbability = 0.72
        static let severeSimilarity = 0.12
        static let disagreementSimilarity = 0.20
        static let fullReviewSimilarity = 0.28
        static let severeLengthRatio = 1.50
        static let fullReviewLengthRatio = 1.70
    }

    public static func assess(
        _ segments: [WhisperSegmentCandidates]
    ) -> LocalTranscriptionAssessment {
        var evaluatedSegments: [EvaluatedWhisperSegment] = []
        var selectedTexts: [String] = []
        var cloudReasons: [String] = []

        for segment in segments.sorted(by: { $0.index < $1.index }) {
            let evaluated = segment.candidates.map { candidate in
                EvaluatedWhisperCandidate(
                    candidate: candidate,
                    metrics: metrics(for: candidate)
                )
            }
            let decision = decide(evaluated)
            if let selected = decision.selected {
                selectedTexts.append(selected.candidate.text)
            }
            if let reason = decision.cloudReason {
                cloudReasons.append("第\(segment.index + 1)段：\(reason)")
            }
            evaluatedSegments.append(EvaluatedWhisperSegment(
                index: segment.index,
                offset: segment.offset,
                duration: segment.duration,
                candidates: evaluated,
                selectedProfile: decision.selected?.candidate.profile,
                cloudReason: decision.cloudReason
            ))
        }

        return LocalTranscriptionAssessment(
            selectedText: mergeSegmentTexts(selectedTexts),
            segments: evaluatedSegments,
            cloudReasons: cloudReasons
        )
    }

    /// Pathumma 已覆盖全片后，挑出需要通用模型复核的分段。
    /// 所有分段都达到严格条件时直接采用专用模型，避免每条泰语视频重复跑两次。
    public static func generalReviewIndexes(for segments: [WhisperSegmentCandidates]) -> [Int] {
        let primaryCandidates = segments.compactMap { segment -> (index: Int, candidate: WhisperSegmentCandidate, metrics: TranscriptionCandidateMetrics)? in
            guard let candidate = segment.candidates.first(where: { $0.profile == .thaiSpecialistGreedy }) else {
                return nil
            }
            return (segment.index, candidate, metrics(for: candidate))
        }
        guard primaryCandidates.count == segments.count else {
            return segments.map(\.index)
        }

        let needsReview = primaryCandidates.filter { requiresGeneralReview($0.candidate, metrics: $0.metrics) }
        guard !needsReview.isEmpty else { return [] }

        // 通用模型只复核风险最高的两个分段。泰语方言、数字和单位本身不是风险，
        // 否则带货口播会几乎整片触发第二模型，既慢又更容易引入跨模型错词。
        let ranked = needsReview.sorted { left, right in
            reviewRisk(left.candidate, metrics: left.metrics) > reviewRisk(right.candidate, metrics: right.metrics)
        }
        var indexes = Set(ranked.prefix(2).map(\.index))

        // 只有一个风险段时，再抽一段内容最完整的正常口播做交叉验证。
        if indexes.count == 1, let representative = primaryCandidates
            .filter({ !indexes.contains($0.index) })
            .max(by: { qualityScore($0.metrics) < qualityScore($1.metrics) }) {
            indexes.insert(representative.index)
        }
        return indexes.sorted()
    }

    /// 抽查段存在实质分歧时，升级为完整双模型复核，避免把一条难视频误判为简单视频。
    public static func requiresFullGeneralReview(
        _ segments: [WhisperSegmentCandidates],
        reviewedIndexes: [Int]
    ) -> Bool {
        for index in reviewedIndexes {
            guard let segment = segments.first(where: { $0.index == index }),
                  let specialist = segment.candidates.first(where: { $0.profile == .thaiSpecialistGreedy }),
                  let general = segment.candidates.first(where: { $0.profile == .generalBeam }),
                  metrics(for: specialist).isValid,
                  metrics(for: general).isValid else {
                continue
            }

            if hasFactConflict(specialist.text, general.text) {
                return true
            }
            let similarity = trigramJaccard(specialist.text, general.text)
            let shorterLength = max(1, min(specialist.text.count, general.text.count))
            let lengthRatio = Double(max(specialist.text.count, general.text.count)) / Double(shorterLength)
            let specialistProbability = specialist.meanTokenProbability
            let generalProbability = general.meanTokenProbability
            if similarity < Thresholds.fullReviewSimilarity,
               (lengthRatio > Thresholds.fullReviewLengthRatio
                || specialistProbability == nil
                || generalProbability == nil
                || min(specialistProbability ?? 0, generalProbability ?? 0) < 0.70) {
                return true
            }
        }
        return false
    }

    private static func decide(
        _ candidates: [EvaluatedWhisperCandidate]
    ) -> (selected: EvaluatedWhisperCandidate?, cloudReason: String?) {
        let valid = candidates.filter(\.metrics.isValid)
        guard !valid.isEmpty else {
            return (bestCandidate(in: candidates), "两个本地候选都未通过质量检查")
        }

        if valid.count == 1 {
            return (valid[0], nil)
        }

        let first = valid[0]
        let second = valid[1]
        if hasFactConflict(first.candidate.text, second.candidate.text) {
            return (bestCandidate(in: valid), "数字或计量单位存在冲突")
        }

        let similarity = trigramJaccard(first.candidate.text, second.candidate.text)
        let shorterLength = max(1, min(first.metrics.characterCount, second.metrics.characterCount))
        let lengthRatio = Double(max(first.metrics.characterCount, second.metrics.characterCount)) / Double(shorterLength)
        if similarity < Thresholds.severeSimilarity {
            return (bestCandidate(in: valid), "两个本地候选内容几乎完全不同")
        }
        if similarity < Thresholds.disagreementSimilarity, lengthRatio > Thresholds.severeLengthRatio {
            return (bestCandidate(in: valid), "两个本地候选严重不一致")
        }

        return (bestCandidate(in: valid), nil)
    }

    private static func bestCandidate(
        in candidates: [EvaluatedWhisperCandidate]
    ) -> EvaluatedWhisperCandidate? {
        return candidates.max { qualityScore($0.metrics) < qualityScore($1.metrics) }
    }

    private static func metrics(for candidate: WhisperSegmentCandidate) -> TranscriptionCandidateMetrics {
        let normalized = normalizedText(candidate.text)
        let characters = Array(normalized)
        let scalarLetters = candidate.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let thaiLetters = scalarLetters.filter { (0x0E00...0x0E7F).contains(Int($0.value)) }
        let thaiRatio = scalarLetters.isEmpty ? 0 : Double(thaiLetters.count) / Double(scalarLetters.count)
        let density = Double(characters.count) / max(candidate.duration, 1)
        let diversity = trigramDiversity(normalized)
        let repetitionLoop = isRepetitionLoop(candidate.text, trigramDiversity: diversity)
        let probabilityIsValid = candidate.meanTokenProbability.map { $0 >= Thresholds.minimumTokenProbability } ?? true
        let isValid = characters.count >= Thresholds.minimumCharacters
            && thaiRatio >= Thresholds.minimumThaiRatio
            && density >= Thresholds.minimumCharacterDensity
            && probabilityIsValid
            && !repetitionLoop

        return TranscriptionCandidateMetrics(
            characterCount: characters.count,
            characterDensity: density,
            thaiScriptRatio: thaiRatio,
            trigramDiversity: diversity,
            meanTokenProbability: candidate.meanTokenProbability,
            tokenProbabilityAvailable: candidate.meanTokenProbability != nil,
            isRepetitionLoop: repetitionLoop,
            isValid: isValid
        )
    }

    private static func requiresGeneralReview(
        _ candidate: WhisperSegmentCandidate,
        metrics: TranscriptionCandidateMetrics
    ) -> Bool {
        guard metrics.isValid,
              metrics.thaiScriptRatio >= Thresholds.reviewThaiRatio,
              metrics.characterDensity >= Thresholds.reviewCharacterDensity,
              metrics.trigramDiversity >= Thresholds.reviewTrigramDiversity,
              !containsLongLatinRun(candidate.text) else {
            return true
        }

        // 缺少 token 概率是独立的不确定状态，不能伪装成固定中等置信度。
        guard metrics.tokenProbabilityAvailable else { return true }
        if let probability = metrics.meanTokenProbability, probability < Thresholds.reviewTokenProbability {
            return true
        }
        return false
    }

    private static func reviewRisk(
        _ candidate: WhisperSegmentCandidate,
        metrics: TranscriptionCandidateMetrics
    ) -> Double {
        var risk = 0.0
        if !metrics.isValid { risk += 100 }
        risk += max(0, Thresholds.reviewThaiRatio - metrics.thaiScriptRatio) * 40
        risk += max(0, Thresholds.reviewCharacterDensity - metrics.characterDensity) * 12
        risk += max(0, Thresholds.reviewTrigramDiversity - metrics.trigramDiversity) * 16
        if let probability = metrics.meanTokenProbability {
            risk += max(0, Thresholds.reviewTokenProbability - probability) * 30
        } else {
            risk += 20
        }
        if containsLongLatinRun(candidate.text) { risk += 30 }
        if metrics.isRepetitionLoop { risk += 40 }
        return risk
    }

    private static func containsLongLatinRun(_ text: String) -> Bool {
        var runLength = 0
        for scalar in text.unicodeScalars {
            if (65...90).contains(scalar.value) || (97...122).contains(scalar.value) {
                runLength += 1
                if runLength >= 4 { return true }
            } else {
                runLength = 0
            }
        }
        return false
    }

    private static func qualityScore(_ metrics: TranscriptionCandidateMetrics) -> Double {
        let densityScore = min(metrics.characterDensity / 10, 1) * 30
        let probabilityScore = (metrics.meanTokenProbability ?? 0) * 30
        let diversityScore = min(metrics.trigramDiversity / 0.60, 1) * 20
        let scriptScore = metrics.thaiScriptRatio * 20
        return densityScore + probabilityScore + diversityScore + scriptScore
    }

    private static func normalizedText(_ text: String) -> String {
        String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
            .precomposedStringWithCanonicalMapping
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let characters = Array(normalizedText(text))
        guard characters.count >= 3 else { return Set(characters.map(String.init)) }
        return Set((0...(characters.count - 3)).map { String(characters[$0...($0 + 2)]) })
    }

    private static func trigramJaccard(_ left: String, _ right: String) -> Double {
        let leftGrams = trigrams(left)
        let rightGrams = trigrams(right)
        let union = leftGrams.union(rightGrams)
        guard !union.isEmpty else { return 1 }
        return Double(leftGrams.intersection(rightGrams).count) / Double(union.count)
    }

    private static func trigramDiversity(_ text: String) -> Double {
        let characters = Array(text)
        guard characters.count >= 3 else { return characters.isEmpty ? 0 : 1 }
        let grams = Set((0...(characters.count - 3)).map { String(characters[$0...($0 + 2)]) })
        return Double(grams.count) / Double(characters.count - 2)
    }

    private static func isRepetitionLoop(_ text: String, trigramDiversity: Double) -> Bool {
        let tokens = text.split { $0.isWhitespace }.map(String.init)
        if tokens.count >= 6 {
            let uniqueRatio = Double(Set(tokens).count) / Double(tokens.count)
            if uniqueRatio < 0.35 { return true }
        }
        return normalizedText(text).count >= 18 && trigramDiversity < 0.25
    }

    private static func hasFactConflict(_ left: String, _ right: String) -> Bool {
        let leftFacts = factTokens(in: left)
        let rightFacts = factTokens(in: right)
        guard !leftFacts.isEmpty, !rightFacts.isEmpty else { return false }
        return leftFacts != rightFacts
    }

    private static func factTokens(in text: String) -> Set<String> {
        let pattern = #"[0-9๐-๙]+(?:[.,][0-9๐-๙]+)?\s*(?:กรัม|กิโลกรัม|กก|มล|ลิตร|บาท|เปอร์เซ็นต์|%)?"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]).replacingOccurrences(of: " ", with: "") }
        })
    }

    private static func mergeSegmentTexts(_ segmentTexts: [String]) -> String {
        var merged = ""
        for text in segmentTexts.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !text.isEmpty {
            if merged.isEmpty {
                merged = text
                continue
            }
            let overlap = longestBoundaryOverlap(merged, text)
            if overlap >= 8 {
                merged += String(text.dropFirst(overlap))
            } else {
                merged += " " + text
            }
        }
        return merged
    }

    private static func longestBoundaryOverlap(_ left: String, _ right: String) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var length = min(leftCharacters.count, rightCharacters.count, 120)
        while length >= 8 {
            if Array(leftCharacters.suffix(length)) == Array(rightCharacters.prefix(length)) {
                return length
            }
            length -= 1
        }
        return 0
    }
}
