import Foundation
import VidLingoCore

enum TranscriptionQualityEvaluator {
    static func assess(
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
    static func generalReviewIndexes(for segments: [WhisperSegmentCandidates]) -> [Int] {
        let primaryCandidates = segments.compactMap { segment -> (index: Int, candidate: WhisperSegmentCandidate, metrics: TranscriptionCandidateMetrics)? in
            guard let candidate = segment.candidates.first(where: { $0.profile == .thaiSpecialistGreedy }) else {
                return nil
            }
            return (segment.index, candidate, metrics(for: candidate))
        }
        guard primaryCandidates.count == segments.count else {
            return segments.map(\.index)
        }

        let needsReview = primaryCandidates.filter { !isStrictHighConfidence($0.candidate, metrics: $0.metrics) }
        guard !needsReview.isEmpty else { return [] }

        // 除风险段外，再抽一段最完整的正常口播交叉验证，防止流畅但明显错词的结果直接放行。
        let representative = primaryCandidates
            .filter { candidate in
                !needsReview.contains { riskyCandidate in riskyCandidate.index == candidate.index }
            }
            .max { qualityScore($0.metrics) < qualityScore($1.metrics) }
            ?? primaryCandidates.max { qualityScore($0.metrics) < qualityScore($1.metrics) }

        var indexes = Set(needsReview.map(\.index))
        if let representative {
            indexes.insert(representative.index)
        }
        return indexes.sorted()
    }

    /// 抽查段存在实质分歧时，升级为完整双模型复核，避免把一条难视频误判为简单视频。
    static func requiresFullGeneralReview(
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
            if similarity < 0.55 || lengthRatio > 1.35 {
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
        if similarity < 0.12 {
            return (bestCandidate(in: valid), "两个本地候选内容几乎完全不同")
        }
        if similarity < 0.20, lengthRatio > 1.50 {
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
        let probabilityIsValid = candidate.meanTokenProbability.map { $0 >= 0.55 } ?? true
        let isValid = characters.count >= 12
            && thaiRatio >= 0.80
            && density >= 2.0
            && probabilityIsValid
            && !repetitionLoop

        return TranscriptionCandidateMetrics(
            characterCount: characters.count,
            characterDensity: density,
            thaiScriptRatio: thaiRatio,
            trigramDiversity: diversity,
            meanTokenProbability: candidate.meanTokenProbability,
            isRepetitionLoop: repetitionLoop,
            isValid: isValid
        )
    }

    private static func isStrictHighConfidence(
        _ candidate: WhisperSegmentCandidate,
        metrics: TranscriptionCandidateMetrics
    ) -> Bool {
        guard metrics.isValid,
              let probability = metrics.meanTokenProbability,
              probability >= 0.80,
              metrics.thaiScriptRatio >= 0.95,
              metrics.characterDensity >= 4.0,
              metrics.trigramDiversity >= 0.55,
              !containsLongLatinRun(candidate.text),
              !containsIsanMarkers(candidate.text),
              factTokens(in: candidate.text).isEmpty,
              !containsThaiFactPhrase(candidate.text) else {
            return false
        }
        return true
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

    private static func containsIsanMarkers(_ text: String) -> Bool {
        let markers = ["เฮา", "บ่", "เบิ่ง", "อิหลี", "อีหลี", "จังซี่", "จั่งซี้", "เด้อ", "คั่นไผ", "ฮอด", "ฮอย"]
        return markers.reduce(into: 0) { count, marker in
            if text.contains(marker) { count += 1 }
        } >= 2
    }

    private static func containsThaiFactPhrase(_ text: String) -> Bool {
        let pattern = #"(?:หลัก(?:สิบ|ร้อย|พัน|หมื่น|แสน|ล้าน)|(?:หนึ่ง|สอง|สาม|สี่|ห้า|หก|เจ็ด|แปด|เก้า|สิบ|ร้อย|พัน)\s*(?:ตัว|ชิ้น|บาท|กรัม|กิโลกรัม|กก|มล|ลิตร|ปี|เดือน))"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func qualityScore(_ metrics: TranscriptionCandidateMetrics) -> Double {
        let densityScore = min(metrics.characterDensity / 10, 1) * 30
        let probabilityScore = (metrics.meanTokenProbability ?? 0.65) * 30
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
