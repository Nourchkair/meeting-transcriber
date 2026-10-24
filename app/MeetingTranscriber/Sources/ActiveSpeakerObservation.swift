@preconcurrency import ApplicationServices
import Foundation

/// A short interval during which a meeting client explicitly identified the
/// displayed participant as speaking. Accessibility text and screenshots are
/// never persisted; only the extracted name and recording-relative timing are.
struct ActiveSpeakerInterval: Codable, Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let name: String
}

/// Conservative interpretation of explicit meeting-client speaking labels.
/// Focus, selection, roster order, and tile prominence are deliberately not
/// accepted as evidence that a participant produced the audio.
enum ActiveSpeakerCueParser {
    private static let speakingMarkers = [
        "is currently speaking", "currently speaking", "is speaking", "speaking now",
        "is currently talking", "currently talking", "is talking", "talking now",
        "está hablando", "está falando", "est en train de parler", "spricht gerade",
        "sta parlando",
    ]

    static func containsSpeakingCue(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("active speaker")
            || lower.contains("active-speaker")
            || speakingMarkers.contains(where: lower.contains)
            || lower.contains("hablando ahora")
            || lower.contains("falando agora")
    }

    /// Extract a name only when the accessibility text itself ties it to an
    /// explicit speaking marker, or when a marker and one unambiguous name are
    /// exposed on the same accessibility element.
    static func name(from strings: [String]) -> String? {
        let directNames = Set(strings.compactMap(nameInSpeakingSentence))
        if !directNames.isEmpty {
            return directNames.count == 1 ? directNames.first : nil
        }

        guard strings.contains(where: containsSpeakingCue) else { return nil }
        let candidates = Set(strings
            .filter { !containsSpeakingCue($0) }
            .flatMap { ParticipantReader.filterParticipantNames([$0]) })
        return candidates.count == 1 ? candidates.first : nil
    }

    private static func nameInSpeakingSentence(_ text: String) -> String? {
        for marker in speakingMarkers {
            guard let range = text.range(of: marker, options: [.caseInsensitive]) else { continue }
            let prefix = String(text[..<range.lowerBound])
            if let name = cleanName(prefix) { return name }
        }

        let markerForms = ["active speaker:", "currently speaking:", "speaking:"]
        for marker in markerForms {
            guard let range = text.range(of: marker, options: [.caseInsensitive]) else { continue }
            let suffix = String(text[range.upperBound...])
            if let name = cleanName(suffix) { return name }
        }

        if let range = text.range(of: "active speaker", options: [.caseInsensitive]) {
            let before = String(text[..<range.lowerBound])
            let after = String(text[range.upperBound...])
            if let name = cleanName(before) { return name }
            if let name = cleanName(after) { return name }
        }
        return nil
    }

    private static func cleanName(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :;,.—–-()[]"))
        guard let name = ParticipantReader.filterParticipantNames([value]).first,
              name.caseInsensitiveCompare("active speaker") != .orderedSame else { return nil }
        return name
    }
}

/// Polls one meeting process's accessibility tree. The caller supplies the
/// detected meeting's PID; for browser meetings this is the Chromium process
/// that owns the active meeting tab. If multiple visible windows expose
/// different active speakers, the reader abstains.
enum ActiveSpeakerReader {
    private static let maximumDepth = 20
    private static let maximumNodes = 400
    private static let treeAttributes: [String] = [
        kAXTitleAttribute,
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
        "AXLabel",
        "AXIdentifier",
        kAXChildrenAttribute,
    ]

    static func read(pid: pid_t) -> String? {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var visited = 0
        let result = readElement(app, depth: 0, visited: &visited)
        return result.candidates.count == 1 ? result.candidates.first : nil
    }

    private struct TreeResult {
        var candidates: Set<String> = []
        var visibleNames: Set<String> = []
        var hasSpeakingCue = false
    }

    private static func readElement(_ element: AXUIElement, depth: Int, visited: inout Int) -> TreeResult {
        guard !Task.isCancelled, depth <= maximumDepth, visited < maximumNodes else { return TreeResult() }
        visited += 1

        AXUIElementSetMessagingTimeout(element, 0.2)
        var rawValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element, treeAttributes as CFArray, [], &rawValues,
        ) == .success, let values = rawValues as? [Any] else { return TreeResult() }
        let ownStrings = values.prefix(treeAttributes.count - 1).enumerated().compactMap { index, value -> String? in
            guard let value = value as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 5, !ActiveSpeakerCueParser.containsSpeakingCue(trimmed) { return nil }
            return trimmed.isEmpty || trimmed.count > 240 ? nil : trimmed
        }
        var result = TreeResult(
            visibleNames: Set(ownStrings
                .filter { !ActiveSpeakerCueParser.containsSpeakingCue($0) }
                .flatMap { ParticipantReader.filterParticipantNames([$0]) }),
            hasSpeakingCue: ownStrings.contains(where: ActiveSpeakerCueParser.containsSpeakingCue),
        )
        if let name = ActiveSpeakerCueParser.name(from: ownStrings) {
            result.candidates.insert(name)
        }

        guard let children = values.last as? [AXUIElement] else {
            return result
        }
        for child in children where visited < maximumNodes {
            let childResult = readElement(child, depth: depth + 1, visited: &visited)
            result.candidates.formUnion(childResult.candidates)
            result.visibleNames.formUnion(childResult.visibleNames)
            result.hasSpeakingCue = result.hasSpeakingCue || childResult.hasSpeakingCue
        }

        // Some clients expose the speaking state on a tile/container and its
        // displayed name in a child label. Only accept that association when
        // the marked subtree contains exactly one plausible participant name.
        if result.hasSpeakingCue, result.visibleNames.count == 1, let name = result.visibleNames.first {
            result.candidates.insert(name)
        }
        return result
    }
}

/// Thread-safe timeline shared by the recording task and the accessibility
/// polling task. Stopping a recording snapshots it synchronously; it never
/// waits for an in-flight Accessibility request to return.
final class ActiveSpeakerTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var intervals: [ActiveSpeakerInterval] = []
    private var currentName: String?
    private var currentStart: TimeInterval?
    private var isFinished = false

    func observe(name: String?, at offset: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, name != currentName else { return }
        if let currentName, let currentStart, offset > currentStart {
            intervals.append(ActiveSpeakerInterval(start: currentStart, end: offset, name: currentName))
        }
        currentName = name
        currentStart = name == nil ? nil : max(0, offset)
    }

    func finish(at offset: TimeInterval) -> [ActiveSpeakerInterval] {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return intervals }
        if let currentName, let currentStart, offset > currentStart {
            intervals.append(ActiveSpeakerInterval(start: currentStart, end: offset, name: currentName))
        }
        currentName = nil
        currentStart = nil
        isFinished = true
        return intervals
    }
}

/// Records the active identity timeline while the meeting is being captured.
/// It stores only names and offsets, never the source accessibility tree.
enum ActiveSpeakerCapture {
    static func collect(pid: pid_t, recordingStartUptime: TimeInterval, timeline: ActiveSpeakerTimeline) async {
        while !Task.isCancelled {
            let scanStart = ProcessInfo.processInfo.systemUptime
            let name = ActiveSpeakerReader.read(pid: pid)
            guard !Task.isCancelled else { break }
            let scanEnd = ProcessInfo.processInfo.systemUptime
            let observationTime = (scanStart + scanEnd) / 2 - recordingStartUptime
            timeline.observe(name: name, at: max(0, observationTime))

            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                break
            }
        }
    }
}

/// Assigns a displayed participant name to a diarized speaker only when the
/// same identity dominates enough of that speaker's observed speech. Ambiguous
/// or sparse evidence leaves the diarizer's generic/voice-matched name intact.
enum ActiveSpeakerNameMatcher {
    private static let minimumObservedSeconds: TimeInterval = 2.0
    private static let minimumSegmentCoverage = 0.55
    private static let minimumNameShare = 0.82
    private static let minimumLeadSeconds: TimeInterval = 1.0

    static func applying(
        _ intervals: [ActiveSpeakerInterval]?,
        to mapping: [String: String],
        segments: [PipelineQueue.SpeakerNamingData.Segment],
        speakingTimes: [String: TimeInterval],
    ) -> [String: String] {
        guard let intervals, !intervals.isEmpty else { return mapping }
        let speakers = Set(segments.map(\.speaker))
        var assignments: [String: String] = [:]

        for speaker in speakers {
            let speakerSegments = segments.filter { $0.speaker == speaker && $0.end > $0.start }
            let duration = max(
                speakingTimes[speaker] ?? 0,
                speakerSegments.reduce(0) { $0 + ($1.end - $1.start) },
            )
            guard duration > 0 else { continue }

            var overlapByName: [String: TimeInterval] = [:]
            for interval in intervals where interval.end > interval.start {
                let overlap = speakerSegments.reduce(0.0) { partial, segment in
                    partial + max(0, min(segment.end, interval.end) - max(segment.start, interval.start))
                }
                if overlap > 0 {
                    overlapByName[interval.name, default: 0] += overlap
                }
            }
            let ranked = overlapByName.sorted { $0.value > $1.value }
            guard let best = ranked.first,
                  best.value >= minimumObservedSeconds,
                  best.value / duration >= minimumSegmentCoverage else { continue }
            let observed = ranked.reduce(0) { $0 + $1.value }
            guard best.value / observed >= minimumNameShare else { continue }
            let runnerUp = ranked.dropFirst().first?.value ?? 0
            guard best.value - runnerUp >= minimumLeadSeconds else { continue }
            assignments[speaker] = best.key
        }

        // A single displayed name cannot safely identify two diarized voices.
        let speakersByName = assignments.reduce(into: [String: [String]]()) { grouped, entry in
            grouped[entry.value, default: []].append(entry.key)
        }
        for (name, matchedSpeakers) in speakersByName where matchedSpeakers.count > 1 {
            for speaker in matchedSpeakers where assignments[speaker] == name {
                assignments.removeValue(forKey: speaker)
            }
        }

        var merged = mapping
        for (speaker, name) in assignments {
            merged[speaker] = name
        }
        return merged
    }
}
