import Foundation

struct WikiRuntimeContext {
    let repoRoot: URL
    let wikiRoot: URL
    let codex: CodexSettings
}

struct PageFrontmatter {
    let title: String
    let tags: [String]
    let oneLiner: String
    let dateAdded: String
}

struct WikiPageSummary {
    let path: URL
    let frontmatter: PageFrontmatter
}

struct ClusterMutation {
    let path: URL
    let content: String?
}

private struct ClusterSummaryOutput: Codable {
    let summary: String
}

private let pageDatePattern = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}$"#)
private let wikiTagPattern = try! NSRegularExpression(pattern: #"^[a-z0-9][a-z0-9-]*$"#)
func loadWikiRuntimeContextFromEnvironment() throws -> WikiRuntimeContext {
    let env = ProcessInfo.processInfo.environment
    guard let repoRoot = normalizeEnvPath(env["WISP_REPO_ROOT"]) else {
        throw AppError.io("WISP_REPO_ROOT is not set")
    }
    guard let wikiRoot = normalizeEnvPath(env["WISP_WIKI_ROOT"]) else {
        throw AppError.io("WISP_WIKI_ROOT is not set")
    }
    guard let baseURL = normalizeEnvValue(env["WISP_CODEX_BASE_URL"]),
          let authFile = normalizeEnvPath(env["WISP_CODEX_AUTH_FILE"]),
          let model = normalizeEnvValue(env["WISP_CODEX_MODEL"]),
          let reasoningEffort = normalizeEnvValue(env["WISP_CODEX_REASONING_EFFORT"]) else {
        throw AppError.io("Wisp write helper is missing Codex configuration in the environment")
    }

    return WikiRuntimeContext(
        repoRoot: repoRoot,
        wikiRoot: wikiRoot,
        codex: CodexSettings(
            baseURL: baseURL,
            authFile: authFile,
            model: model,
            reasoningEffort: reasoningEffort
        )
    )
}

func runInit(config: InitConfig) throws {
    let fm = FileManager.default
    let root = config.targetRoot
    let repoConfigDir = config.configPath.deletingLastPathComponent()
    let schemaPath = wikiSchemaPath(wikiRoot: root)

    try fm.createDirectory(at: repoConfigDir, withIntermediateDirectories: true)

    let renderedConfig = renderWorkspaceConfig(repoRoot: config.repoRoot, wikiRoot: root)
    try renderedConfig.write(
        to: config.configPath,
        atomically: true,
        encoding: .utf8
    )
    if !fm.fileExists(atPath: config.configExamplePath.path) {
        try renderWorkspaceConfig(repoRoot: config.repoRoot, wikiRoot: nil).write(
            to: config.configExamplePath,
            atomically: true,
            encoding: .utf8
        )
    }
    if !fm.fileExists(atPath: schemaPath.path) {
        try initialSchemaTemplate().write(to: schemaPath, atomically: true, encoding: .utf8)
    }

    print("wiki workspace ready at \(root.path)")
    print("config updated: \(config.configPath.path)")
}

func renderWorkspaceConfig(repoRoot: URL, wikiRoot: URL?) -> String {
    [
        "# Wisp workspace configuration",
        "paths:",
        "  repo_root: \(quoteYAMLScalar(repoRoot.path))",
        "  wiki_root: \(quoteYAMLScalar(wikiRoot?.path ?? ""))",
        "model:",
        "  name: \"gpt-5.4\"",
        "  reasoning_effort: \"medium\""
    ].joined(separator: "\n") + "\n"
}

func quoteYAMLScalar(_ value: String) -> String {
    "\"" + value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"") + "\""
}

func initialSchemaTemplate() -> String {
    [
        "# Tag Vocabulary",
        "",
        "Use `short-tag: alias, alias, alias` format.",
        "The short tag is canonical and is what notes must use in frontmatter.",
        "Aliases are optional and help retrieval.",
        "",
        "ml: machine learning",
        "llm: large language model, foundation model"
    ].joined(separator: "\n") + "\n"
}

func handleWikiWrite(rawPath: String, content: String, context: WikiRuntimeContext) throws -> String {
    let target = resolveRelativeToRoot(rawPath, root: context.wikiRoot)
    try ensureWithinRoot(target, root: context.wikiRoot, toolName: "write")
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try content.write(to: target, atomically: true, encoding: .utf8)
    return "wrote \(relativeWikiPath(target, wikiRoot: context.wikiRoot))"
}

private func parseSchemaTags(from content: String) throws -> Set<String> {
    var tags = Set<String>()
    for rawLine in content.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            continue
        }
        let canonical = parseCanonicalSchemaTag(from: trimmed)
        guard let canonical else {
            continue
        }
        tags.insert(canonical)
    }
    if tags.isEmpty {
        throw AppError.io("schema.md must contain at least one valid tag line")
    }
    return tags
}

private func parseCanonicalSchemaTag(from line: String) -> String? {
    let candidate: String
    if let separator = line.firstIndex(of: ":") {
        candidate = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    } else {
        candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !candidate.isEmpty, matches(wikiTagPattern, text: candidate) else {
        return nil
    }
    return candidate
}

private func loadSchemaTags(schemaPath: URL) throws -> Set<String> {
    let content = try loadRequiredTextFile(schemaPath, name: schemaPath.lastPathComponent)
    return try parseSchemaTags(from: content)
}

private func validatePages(_ pages: [WikiPageSummary], against schemaTags: Set<String>) throws {
    for page in pages {
        try validatePageFrontmatter(page.frontmatter, schemaTags: schemaTags, path: page.path)
    }
}

private func validatePageFrontmatter(_ frontmatter: PageFrontmatter, schemaTags: Set<String>, path: URL) throws {
    if frontmatter.tags.isEmpty || frontmatter.tags.count > 4 {
        throw AppError.io("Page \(path.lastPathComponent) must have between 1 and 4 tags")
    }
    let invalidTags = frontmatter.tags.filter { !schemaTags.contains($0) }
    if !invalidTags.isEmpty {
        throw AppError.io("Page \(path.lastPathComponent) uses tags missing from schema.md: \(invalidTags.joined(separator: ", "))")
    }
    guard matches(pageDatePattern, text: frontmatter.dateAdded) else {
        throw AppError.io("Page \(path.lastPathComponent) has invalid date_added; expected YYYY-MM-DD")
    }
}

private func parsePageFrontmatter(_ content: String, path: URL) throws -> PageFrontmatter {
    let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
    guard normalized.hasPrefix("---\n") else {
        throw AppError.io("Page \(path.lastPathComponent) must start with YAML frontmatter")
    }

    let lines = normalized.components(separatedBy: "\n")
    var index = 1
    var fields: [String: String] = [:]
    while index < lines.count {
        let line = lines[index]
        if line == "---" {
            break
        }
        guard let separator = line.firstIndex(of: ":") else {
            throw AppError.io("Invalid frontmatter line in \(path.lastPathComponent): \(line)")
        }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        fields[key] = value
        index += 1
    }
    guard index < lines.count, lines[index] == "---" else {
        throw AppError.io("Page \(path.lastPathComponent) is missing the closing frontmatter delimiter")
    }

    let requiredKeys: Set<String> = ["title", "tags", "one_liner", "date_added"]
    let actualKeys = Set(fields.keys)
    guard actualKeys == requiredKeys else {
        let missing = requiredKeys.subtracting(actualKeys).sorted().joined(separator: ", ")
        let extra = actualKeys.subtracting(requiredKeys).sorted().joined(separator: ", ")
        var parts: [String] = []
        if !missing.isEmpty { parts.append("missing: \(missing)") }
        if !extra.isEmpty { parts.append("extra: \(extra)") }
        throw AppError.io("Page \(path.lastPathComponent) frontmatter keys must be exactly title, tags, one_liner, date_added (\(parts.joined(separator: "; ")))")
    }

    guard let title = normalizeEnvValue(fields["title"]),
          let tagsValue = normalizeEnvValue(fields["tags"]),
          let oneLiner = normalizeEnvValue(fields["one_liner"]),
          let dateAdded = normalizeEnvValue(fields["date_added"]) else {
        throw AppError.io("Page \(path.lastPathComponent) frontmatter contains empty required fields")
    }

    let tags = try parseTagArray(tagsValue, path: path)
    return PageFrontmatter(
        title: title,
        tags: tags,
        oneLiner: oneLiner,
        dateAdded: dateAdded
    )
}

private func parseTagArray(_ raw: String, path: URL) throws -> [String] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("["),
          trimmed.hasSuffix("]") else {
        throw AppError.io("Page \(path.lastPathComponent) tags must use [tag, tag] syntax")
    }
    let innerStart = trimmed.index(after: trimmed.startIndex)
    let innerEnd = trimmed.index(before: trimmed.endIndex)
    let inner = String(trimmed[innerStart..<innerEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    if inner.isEmpty {
        return []
    }
    let tags = inner.split(separator: ",").map {
        String($0).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if Set(tags).count != tags.count {
        throw AppError.io("Page \(path.lastPathComponent) contains duplicate tags")
    }
    let invalid = tags.filter { !matches(wikiTagPattern, text: $0) }
    if !invalid.isEmpty {
        throw AppError.io("Page \(path.lastPathComponent) has invalid tag values: \(invalid.joined(separator: ", "))")
    }
    return tags
}

private func loadWikiPages(wikiRoot: URL) throws -> [WikiPageSummary] {
    let schemaPath = wikiSchemaPath(wikiRoot: wikiRoot).path
    let clustersDir = wikiClustersDirectory(wikiRoot: wikiRoot).path
    guard let enumerator = FileManager.default.enumerator(
        at: wikiRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    var pages: [WikiPageSummary] = []
    for case let fileURL as URL in enumerator {
        guard fileURL.pathExtension == "md" else {
            continue
        }
        let standardized = fileURL.standardizedFileURL
        let path = standardized.path
        if path == schemaPath {
            continue
        }
        if path.hasPrefix(clustersDir + "/") {
            continue
        }
        if path.contains("/.wisp/") {
            continue
        }
        let content = try loadRequiredTextFile(standardized, name: standardized.lastPathComponent)
        let frontmatter = try parsePageFrontmatter(content, path: standardized)
        pages.append(WikiPageSummary(path: standardized, frontmatter: frontmatter))
    }
    return pages.sorted { $0.path.lastPathComponent < $1.path.lastPathComponent }
}

private func planClusterMutations(
    schemaTags: Set<String>,
    pages: [WikiPageSummary],
    tagsToSync: Set<String>?,
    context: WikiRuntimeContext
) throws -> [ClusterMutation] {
    let clustersDir = wikiClustersDirectory(wikiRoot: context.wikiRoot)
    let existingClusterTags = try loadExistingClusterTags(clustersDir: clustersDir)
    let candidateTags: [String]
    if let tagsToSync {
        candidateTags = Array(tagsToSync.union(existingClusterTags)).sorted()
    } else {
        candidateTags = Array(schemaTags.union(existingClusterTags)).sorted()
    }

    var mutations: [ClusterMutation] = []
    for tag in candidateTags {
        let clusterPath = clustersDir.appendingPathComponent("\(tag).md")
        guard schemaTags.contains(tag) else {
            if FileManager.default.fileExists(atPath: clusterPath.path) {
                mutations.append(ClusterMutation(path: clusterPath, content: nil))
            }
            continue
        }

        let matchingPages = pages
            .filter { $0.frontmatter.tags.contains(tag) }
            .sorted { lhs, rhs in
                if lhs.frontmatter.dateAdded == rhs.frontmatter.dateAdded {
                    return lhs.frontmatter.title < rhs.frontmatter.title
                }
                return lhs.frontmatter.dateAdded > rhs.frontmatter.dateAdded
            }
        if matchingPages.count < 3 {
            if FileManager.default.fileExists(atPath: clusterPath.path) {
                mutations.append(ClusterMutation(path: clusterPath, content: nil))
            }
            continue
        }

        let summary = try generateClusterSummary(tag: tag, pages: matchingPages, context: context)
        mutations.append(
            ClusterMutation(
                path: clusterPath,
                content: renderClusterDocument(tag: tag, summary: summary)
            )
        )
    }
    return mutations
}

private func loadExistingClusterTags(clustersDir: URL) throws -> Set<String> {
    guard FileManager.default.fileExists(atPath: clustersDir.path) else {
        return []
    }
    let fileURLs = try FileManager.default.contentsOfDirectory(
        at: clustersDir,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )
    return Set(
        fileURLs
            .filter { $0.pathExtension == "md" }
            .map { $0.deletingPathExtension().lastPathComponent }
    )
}

private func applyClusterMutations(_ mutations: [ClusterMutation]) throws {
    let fm = FileManager.default
    for mutation in mutations {
        if let content = mutation.content {
            try content.write(to: mutation.path, atomically: true, encoding: .utf8)
        } else if fm.fileExists(atPath: mutation.path.path) {
            try fm.removeItem(at: mutation.path)
        }
    }
}

private func generateClusterSummary(tag: String, pages: [WikiPageSummary], context: WikiRuntimeContext) throws -> String {
    let token = try loadCodexOAuthToken(authFile: context.codex.authFile)
    let url = try CodexOAuth.resolveResponsesURL(baseURL: context.codex.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let sessionID = buildPromptCacheKey(sessionID: "cluster-\(tag)-\(UUID().uuidString.lowercased())")
    let headers = try CodexOAuth.buildSSEHeaders(token: token, sessionID: sessionID)
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }

    let payload = ResponsesRequest(
        model: context.codex.model,
        instructions: try loadRequiredTextFile(
            context.repoRoot.appendingPathComponent("prompts/cluster.md"),
            name: "cluster.md"
        ).trimmingCharacters(in: .whitespacesAndNewlines),
        prompt_cache_key: sessionID,
        store: false,
        stream: true,
        reasoning: ResponsesReasoning(
            effort: context.codex.reasoningEffort,
            summary: "auto"
        ),
        input: [
            buildInputTextMessageItem(
                role: "user",
                text: buildClusterPromptInput(tag: tag, pages: pages)
            )
        ],
        include: ["reasoning.encrypted_content"],
        text: ResponsesTextConfig(
            format: ResponsesTextFormat(
                type: "json_schema",
                name: "wisp_cluster_summary",
                strict: true,
                schema: ResponseSchema(
                    type: "object",
                    properties: ["summary": ResponseSchemaProperty(type: .single("string"))],
                    required: ["summary"],
                    additionalProperties: false
                )
            )
        )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    request.httpBody = try encoder.encode(payload)

    let responseData = try httpRequest(request)
    let decoded = try decodeModelText(from: responseData)
    guard let jsonData = decoded.text.data(using: .utf8) else {
        throw AppError.invalidModelResponse("Cluster summary response was not utf8")
    }
    let parsed = try JSONDecoder().decode(ClusterSummaryOutput.self, from: jsonData)
    let summary = parsed.summary.trimmingCharacters(in: .whitespacesAndNewlines)
    if summary.isEmpty {
        throw AppError.invalidModelResponse("Cluster summary was empty for tag \(tag)")
    }
    return summary
}

private func buildClusterPromptInput(tag: String, pages: [WikiPageSummary]) -> String {
    let lines = pages.map {
        "- title: \($0.frontmatter.title)\n  date_added: \($0.frontmatter.dateAdded)\n  one_liner: \($0.frontmatter.oneLiner)"
    }
    return [
        "tag: \(tag)",
        "page_count: \(pages.count)",
        "pages:",
        lines.joined(separator: "\n")
    ].joined(separator: "\n")
}

private func renderClusterDocument(tag: String, summary: String) -> String {
    [
        "# \(tag)",
        "",
        summary.trimmingCharacters(in: .whitespacesAndNewlines),
        ""
    ].joined(separator: "\n")
}

private func wikiSchemaPath(wikiRoot: URL) -> URL {
    wikiRoot.appendingPathComponent("schema.md").standardizedFileURL
}

private func wikiClustersDirectory(wikiRoot: URL) -> URL {
    wikiRoot.appendingPathComponent("clusters").standardizedFileURL
}

private func relativeWikiPath(_ url: URL, wikiRoot: URL) -> String {
    let rootPath = wikiRoot.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    if path == rootPath {
        return "."
    }
    if path.hasPrefix(rootPath + "/") {
        return String(path.dropFirst(rootPath.count + 1))
    }
    return path
}

private func resolveRelativeToRoot(_ rawPath: String, root: URL) -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("/") {
        return URL(fileURLWithPath: trimmed).standardizedFileURL
    }
    return root.appendingPathComponent(trimmed).standardizedFileURL
}

private func ensureWithinRoot(_ path: URL, root: URL, toolName: String) throws {
    let rootPath = root.standardizedFileURL.path
    let resolvedPath = path.standardizedFileURL.path
    if resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/") {
        return
    }
    throw AppError.io("\(toolName): refusing write outside wiki root: \(rootPath)")
}

private func normalizeEnvValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func normalizeEnvPath(_ value: String?) -> URL? {
    guard let normalized = normalizeEnvValue(value) else {
        return nil
    }
    return URL(fileURLWithPath: normalized).standardizedFileURL
}

private func matches(_ regex: NSRegularExpression, text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    guard let match = regex.firstMatch(in: text, options: [], range: range) else {
        return false
    }
    return match.range == range
}
