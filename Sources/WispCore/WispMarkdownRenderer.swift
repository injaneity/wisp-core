import Foundation

public struct WispMarkdownRenderer: Sendable {
    public init() {}

    public func renderNote(title: String, summary: String, artifacts: [String] = [], content: String = "", date: Date = Date()) -> String {
        renderEntryDocument(title: title, summary: summary, artifacts: artifacts, content: content, extraLines: [], date: date)
    }

    public func renderTask(
        title: String,
        summary: String,
        artifacts: [String] = [],
        content: String = "",
        due: String? = nil,
        time: String? = nil,
        place: String? = nil,
        status: String? = nil,
        date: Date = Date()
    ) -> String {
        renderEntryDocument(
            title: title,
            summary: summary,
            artifacts: artifacts,
            content: content,
            extraLines: [
                "status: \(normalizedMetadataValue(status, defaultValue: "open"))",
                "due: \(normalizedMetadataValue(due, defaultValue: "none"))",
                "time: \(normalizedMetadataValue(time, defaultValue: "none"))",
                "place: \(normalizedMetadataValue(place, defaultValue: "none"))"
            ],
            date: date
        )
    }

    public func slugifyFileStem(_ title: String) -> String {
        let lowered = title.lowercased()
        let pieces = lowered.split { !$0.isLetter && !$0.isNumber }
        let slug = pieces.map(String.init).filter { !$0.isEmpty }.joined(separator: "-")
        return slug.isEmpty ? "untitled" : slug
    }

    public func renderArtifactsLine(_ artifacts: [String]) -> String {
        var seen = Set<String>()
        let cleaned = artifacts
            .compactMap(normalizeArtifactReference)
            .filter { seen.insert($0).inserted }
        if cleaned.isEmpty { return "artifacts: none" }
        return "artifacts: " + cleaned.joined(separator: ", ")
    }

    public func todayString(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    public func normalizeSummaryLine(_ summary: String) -> String {
        summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderEntryDocument(title: String, summary: String, artifacts: [String], content: String, extraLines: [String], date: Date) -> String {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let day = todayString(date: date)
        var lines = [
            "# \(normalizedTitle)",
            "created: \(day)",
            "modified: \(day)",
            "summary: \(normalizeSummaryLine(summary))",
            renderArtifactsLine(artifacts)
        ]
        lines.append(contentsOf: extraLines)
        lines.append("")
        if !normalizedContent.isEmpty {
            lines.append(normalizedContent)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func normalizeArtifactReference(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[[") && trimmed.hasSuffix("]]") {
            let start = trimmed.index(trimmed.startIndex, offsetBy: 2)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
            let inner = trimmed[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !inner.isEmpty else { return nil }
            return "[[\(inner)]]"
        }
        return "[[\(trimmed)]]"
    }

    private func normalizedMetadataValue(_ value: String?, defaultValue: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultValue : trimmed
    }
}
