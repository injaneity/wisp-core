import Foundation
import CryptoKit
import Darwin

struct CLIConfig {
    let verbose: Bool
    let logPath: URL
    let logWriter: EventLogWriter
    let codex: CodexSettings
    let promptConfig: PromptConfig
    let sessionID: String
    let repoRoot: URL
    let wikiRoot: URL
    let workingDirectory: URL
    let workspaceConfigPath: URL?
    let conversationState: ConversationState
}

struct InitConfig {
    let targetRoot: URL
    let repoRoot: URL
    let configPath: URL
    let configExamplePath: URL
}

struct ToolExecutionOutput: Codable {
    let status_code: Int
    let stdout: String
    let stderr: String
    let truncation_mode: String
    let runtime_duration_ms: Int
}

struct ToolResult: Codable {
    let status_code: Int
    let text: String
    let runtime_duration_ms: Int
    let truncated: Bool
    let total_bytes: Int
    let artifact_path: String?
}

struct SessionEvent: Codable {
    let timestamp: String
    let type: String
    let payload: [String: String]
}

final class EventLogWriter {
    private let path: URL
    private let lock = NSLock()
    private var fileHandle: FileHandle?

    init(path: URL) {
        self.path = path
    }

    func reopen() throws {
        lock.lock()
        defer { lock.unlock() }
        try reopenLocked()
    }

    func append(_ event: SessionEvent) throws {
        let data = try JSONEncoder().encode(event)
        guard var line = String(data: data, encoding: .utf8) else {
            throw AppError.io("Could not encode log event")
        }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else {
            throw AppError.io("Could not encode log event line data")
        }

        lock.lock()
        defer { lock.unlock() }
        if fileHandle == nil {
            try reopenLocked()
        }
        guard let fileHandle else {
            throw AppError.io("Could not open log file at \(path.path)")
        }
        try fileHandle.seekToEnd()
        fileHandle.write(lineData)
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }

    private func reopenLocked() throws {
        try? fileHandle?.close()
        fileHandle = nil
        if !FileManager.default.fileExists(atPath: path.path) {
            FileManager.default.createFile(atPath: path.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: path)
        try fileHandle?.seekToEnd()
    }
}

struct CodexSettings {
    let baseURL: String
    let authFile: URL
    let model: String
    let reasoningEffort: String
}

struct WorkspaceConfigValues {
    let repoRoot: URL
    let wikiRoot: URL?
    let model: String?
    let reasoningEffort: String?
    let baseURL: String?
}

struct PromptConfig {
    let systemPrompt: String
    let systemPromptSource: String
}

struct ResponseMessageContent: Encodable {
    let type: String
    let text: String
}

enum ResponseInputItem: Encodable {
    case message(role: String, content: [ResponseMessageContent])
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    enum CodingKeys: String, CodingKey {
        case type
        case role
        case content
        case call_id
        case name
        case arguments
        case output
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .functionCall(let callID, let name, let arguments):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .call_id)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .call_id)
            try container.encode(output, forKey: .output)
        }
    }
}

enum AppError: Error, CustomStringConvertible {
    case missingOAuthToken
    case invalidModelResponse(String)
    case requestFailed(String)
    case io(String)

    var description: String {
        switch self {
        case .missingOAuthToken:
            return "Codex auth file does not contain an access token."
        case .invalidModelResponse(let message):
            return "Invalid model response: \(message)"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .io(let message):
            return "IO error: \(message)"
        }
    }
}

let promptFileName = "prompt.md"
let workspaceConfigRelativePath = ".wisp/config.yaml"
let readOrBashMaxLines = 2_000
let readOrBashMaxBytes = 50 * 1024

@main
struct WispMain {
    static func main() {
        do {
            ensureRuntimeDependencies()
            let config = try parseArgs()
            try prepareDirectories(for: config.logPath)
            try resetSessionLog(logPath: config.logPath)
            try config.logWriter.reopen()
            config.conversationState.reset()
            if config.verbose {
                print("[verbose] prompts.system: \(config.promptConfig.systemPromptSource)")
                if let workspaceConfigPath = config.workspaceConfigPath {
                    print("[verbose] workspace.config: \(workspaceConfigPath.path)")
                }
            }
            print("session initialized (previous session archived if present).")
            print("wisp started. Type `exit` to quit and clear session, or `restart` to clear session and continue.")

            while true {
                print("you> ", terminator: "")
                guard let line = readLine() else { break }
                let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if command == "exit" {
                    try resetSessionLog(logPath: config.logPath)
                    config.conversationState.reset()
                    config.logWriter.close()
                    print("session ended.")
                    break
                }
                if command == "restart" {
                    try resetSessionLog(logPath: config.logPath)
                    try config.logWriter.reopen()
                    config.conversationState.reset()
                    print("session restarted.")
                    continue
                }
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                try runAgentLoop(line, config: config)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}

func isCommandAvailable(_ name: String) -> Bool {
    let env = ProcessInfo.processInfo.environment
    let pathValue = env["PATH"] ?? ""
    let separator = Character(":")
    for rawPart in pathValue.split(separator: separator, omittingEmptySubsequences: true) {
        let directory = String(rawPart)
        let candidate = directory + "/" + name
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return true
        }
    }
    return false
}

func ensureRuntimeDependencies() {
    guard resolveBundledRGDirectory() != nil || isCommandAvailable("rg") else {
        fputs("warning: optional dependency missing: ripgrep\n", stderr)
        return
    }
}

func runBashCommand(command: String, timeoutMs: Int, currentDirectory: URL? = nil) throws -> (statusCode: Int, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = currentDirectory

    var env = ProcessInfo.processInfo.environment
    if let rgDir = resolveBundledRGDirectory() {
        let currentPath = env["PATH"] ?? ""
        env["PATH"] = rgDir + (currentPath.isEmpty ? "" : ":" + currentPath)
    }
    process.environment = env

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    do {
        try process.run()
    } catch {
        throw AppError.requestFailed("Failed to run shell command: \(error.localizedDescription)")
    }

    final class PipeReadState: @unchecked Sendable {
        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
    }
    let readState = PipeReadState()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        readState.lock.lock()
        readState.stdoutData = data
        readState.lock.unlock()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        readState.lock.lock()
        readState.stderrData = data
        readState.lock.unlock()
        group.leave()
    }

    let exitSemaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        exitSemaphore.signal()
    }

    var didTimeout = false
    if exitSemaphore.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
        didTimeout = true
        process.terminate()
        if exitSemaphore.wait(timeout: .now() + .milliseconds(1_500)) == .timedOut,
           process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = exitSemaphore.wait(timeout: .now() + .milliseconds(500))
        }
    }
    process.waitUntilExit()
    group.wait()

    readState.lock.lock()
    let stdoutData = readState.stdoutData
    let stderrData = readState.stderrData
    readState.lock.unlock()
    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    var stderr = String(data: stderrData, encoding: .utf8) ?? ""
    if didTimeout {
        let timeoutMessage = "bash command timed out after \(timeoutMs)ms"
        stderr = stderr.isEmpty ? timeoutMessage : "\(stderr)\n\(timeoutMessage)"
    }

    let status = didTimeout ? 124 : Int(process.terminationStatus)
    return (
        statusCode: status,
        stdout: stdout,
        stderr: stderr
    )
}

func truncateText(text: String, mode: String, maxLines: Int, maxBytes: Int) -> (content: String, truncated: Bool) {
    var content = text
    var truncated = false
    let normalizedMode = mode.lowercased()

    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    if lines.count > maxLines {
        if normalizedMode == "tail" {
            content = lines.suffix(maxLines).joined(separator: "\n")
        } else {
            content = lines.prefix(maxLines).joined(separator: "\n")
        }
        truncated = true
    }

    let byteCount = content.lengthOfBytes(using: .utf8)
    if byteCount > maxBytes {
        if normalizedMode == "tail" {
            content = utf8Suffix(content, maxBytes: maxBytes)
        } else {
            content = utf8Prefix(content, maxBytes: maxBytes)
        }
        truncated = true
    }

    return (content, truncated)
}

func utf8Suffix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var currentBytes = 0
    var startIndex = text.endIndex
    var index = text.endIndex
    while index > text.startIndex {
        let prevIndex = text.index(before: index)
        let scalarBytes = text[prevIndex..<index].utf8.count
        if currentBytes + scalarBytes > maxBytes {
            break
        }
        currentBytes += scalarBytes
        startIndex = prevIndex
        index = prevIndex
    }
    return String(text[startIndex...])
}

func resolveBundledRGDirectory() -> String? {
    let env = ProcessInfo.processInfo.environment
    if let configured = env["WISP_BUNDLED_RG_DIR"],
       !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let path = URL(fileURLWithPath: configured).standardizedFileURL.path
        if FileManager.default.isExecutableFile(atPath: path + "/rg") {
            return path
        }
    }

    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    let candidates = [
        executable.deletingLastPathComponent().appendingPathComponent("bin").path,
        executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/bin").path
    ]
    for candidate in candidates {
        if FileManager.default.isExecutableFile(atPath: candidate + "/rg") {
            return candidate
        }
    }
    return nil
}

func parseArgs() throws -> CLIConfig {
    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    let verbose = try parseCLIFlags(Array(CommandLine.arguments.dropFirst()))
    let workspaceConfig = try resolveOrInitializeWorkspaceConfig(startingAt: workingDirectory)
    return try makeCLIConfig(verbose: verbose, workspaceConfig: workspaceConfig, workingDirectory: workingDirectory)
}

func parseCLIFlags(_ args: [String]) throws -> Bool {
    var verbose = false
    for arg in args {
        switch arg {
        case "--verbose":
            verbose = true
        default:
            throw AppError.io("Unknown argument: \(arg)")
        }
    }
    return verbose
}

func resolveOrInitializeWorkspaceConfig(startingAt workingDirectory: URL) throws -> ResolvedWorkspaceConfig {
    var workspaceConfig = try resolveWorkspaceConfig(startingAt: workingDirectory)
    if workspaceConfig.wikiRoot != nil {
        return workspaceConfig
    }

    let targetRoot = try promptForWikiRoot()
    let dotWisp = workspaceConfig.repoRoot.appendingPathComponent(".wisp")
    try runInit(
        config: InitConfig(
            targetRoot: targetRoot,
            repoRoot: workspaceConfig.repoRoot,
            configPath: dotWisp.appendingPathComponent("config.yaml"),
            configExamplePath: dotWisp.appendingPathComponent("config.yaml.example")
        )
    )
    workspaceConfig = try resolveWorkspaceConfig(startingAt: workspaceConfig.repoRoot)
    return workspaceConfig
}

func makeCLIConfig(verbose: Bool, workspaceConfig: ResolvedWorkspaceConfig, workingDirectory: URL) throws -> CLIConfig {
    guard let wikiRoot = workspaceConfig.wikiRoot else {
        throw AppError.io("Wiki root is still unset after initialization.")
    }
    let logPath = wikiRoot.appendingPathComponent(".wisp/session.jsonl")
    return CLIConfig(
        verbose: verbose,
        logPath: logPath,
        logWriter: EventLogWriter(path: logPath),
        codex: resolveCodexSettings(workspaceConfig: workspaceConfig),
        promptConfig: try loadPromptConfig(repoRoot: workspaceConfig.repoRoot, wikiRoot: wikiRoot),
        sessionID: UUID().uuidString.lowercased(),
        repoRoot: workspaceConfig.repoRoot,
        wikiRoot: wikiRoot,
        workingDirectory: workingDirectory,
        workspaceConfigPath: workspaceConfig.configPath,
        conversationState: ConversationState()
    )
}

func prepareDirectories(for logPath: URL) throws {
    let dir = logPath.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: logPath.path) {
        FileManager.default.createFile(atPath: logPath.path, contents: nil)
    }
}

func resetSessionLog(logPath: URL) throws {
    let fm = FileManager.default
    let archiveDir = logPath.deletingLastPathComponent().appendingPathComponent("archive")
    try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)

    if fm.fileExists(atPath: logPath.path),
       let data = fm.contents(atPath: logPath.path),
       !data.isEmpty {
        let archived = archiveDir.appendingPathComponent("session-\(isoFileNow()).jsonl")
        try data.write(to: archived)
    }
    try Data().write(to: logPath, options: .atomic)
}

func loadCodexOAuthToken(authFile: URL) throws -> String {
    let data = try Data(contentsOf: authFile)
    let json = try JSONSerialization.jsonObject(with: data, options: [])
    guard let obj = json as? [String: Any] else {
        throw AppError.invalidModelResponse("Codex auth file root must be an object")
    }
    guard let tokens = obj["tokens"] as? [String: Any] else {
        throw AppError.invalidModelResponse("Codex auth file missing tokens object")
    }
    guard let token = (tokens["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else {
        throw AppError.missingOAuthToken
    }
    return token
}

func nonEmptyText(_ value: Any?) -> String? {
    switch value {
    case let text as String:
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    case let object as [String: Any]:
        return nonEmptyText(object["value"])
    default:
        return nil
    }
}

func appendLog(type: String, payload: [String: String], writer: EventLogWriter) throws {
    try writer.append(SessionEvent(timestamp: isoNow(), type: type, payload: payload))
}

func jsonObject<T: Encodable>(_ value: T) throws -> Any {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data, options: [])
}

func encodeReplayToolResult(_ value: ToolResult) throws -> String {
    let replayObject: [String: Any] = [
        "status_code": value.status_code,
        "text": value.text,
        "runtime_duration_ms": value.runtime_duration_ms
    ]
    let data = try JSONSerialization.data(withJSONObject: replayObject, options: [.sortedKeys])
    guard let text = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not encode replay tool result JSON text")
    }
    return text
}

func timed<T>(_ operation: () throws -> T) rethrows -> (value: T, durationMs: Int) {
    let start = Date()
    let value = try operation()
    let elapsed = Int(Date().timeIntervalSince(start) * 1000.0)
    return (value, elapsed)
}

func isoNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: Date())
}

func resolveCodexSettings(workspaceConfig: ResolvedWorkspaceConfig) -> CodexSettings {
    let env = ProcessInfo.processInfo.environment
    let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    let authFile = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")

    return CodexSettings(
        baseURL: workspaceConfig.values.baseURL ?? "https://chatgpt.com/backend-api/codex",
        authFile: authFile,
        model: workspaceConfig.values.model ?? "gpt-5.4",
        reasoningEffort: workspaceConfig.values.reasoningEffort ?? "medium"
    )
}

func indentMultiline(_ text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "  \($0)" }
        .joined(separator: "\n")
}

func compactText(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let prefix = trimmed.prefix(max(0, limit))
    let omitted = trimmed.count - prefix.count
    return String(prefix) + "... [truncated \(omitted) chars]"
}

func buildPromptCacheKey(sessionID: String) -> String {
    let stable = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    if stable.isEmpty {
        return ""
    }
    let digest = SHA256.hash(data: Data(stable.utf8))
    let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    return "wisp-\(hex)"
}

func buildToolResult(from output: ToolExecutionOutput, logPath: URL) throws -> ToolResult {
    let rawStdout = output.stdout
    let rawStderr = output.stderr
    var fullText = rawStdout
    if !fullText.isEmpty, !rawStderr.isEmpty, !fullText.hasSuffix("\n") {
        fullText += "\n"
    }
    fullText += rawStderr

    let mode = output.truncation_mode
    let textTruncation = truncateText(
        text: fullText,
        mode: mode,
        maxLines: readOrBashMaxLines,
        maxBytes: readOrBashMaxBytes
    )

    let totalBytes = fullText.lengthOfBytes(using: .utf8)
    let shouldWriteArtifact = textTruncation.truncated
    var artifactPath: String?
    if shouldWriteArtifact {
        artifactPath = try writeToolArtifact(text: fullText, logPath: logPath)
    }

    var textForModel = textTruncation.content
    if shouldWriteArtifact, let artifactPath {
        let omittedBytes = max(0, totalBytes - textTruncation.content.lengthOfBytes(using: .utf8))
        textForModel = textForModel + "\n[truncated \(omittedBytes) bytes; full output: \(artifactPath)]"
    }

    return ToolResult(
        status_code: output.status_code,
        text: textForModel,
        runtime_duration_ms: output.runtime_duration_ms,
        truncated: shouldWriteArtifact,
        total_bytes: totalBytes,
        artifact_path: artifactPath
    )
}

func utf8Prefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var currentBytes = 0
    var endIndex = text.startIndex
    for index in text.indices {
        let nextIndex = text.index(after: index)
        let characterBytes = text[index..<nextIndex].utf8.count
        if currentBytes + characterBytes > maxBytes {
            break
        }
        currentBytes += characterBytes
        endIndex = nextIndex
    }
    return String(text[..<endIndex])
}

func writeToolArtifact(text: String, logPath: URL) throws -> String {
    let artifactsDir = logPath.deletingLastPathComponent().appendingPathComponent("artifacts")
    try FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
    let fileName = "tool-\(isoFileNow())-\(UUID().uuidString.prefix(8)).txt"
    let artifactURL = artifactsDir.appendingPathComponent(fileName)
    try text.write(to: artifactURL, atomically: true, encoding: .utf8)
    return artifactURL.path
}

func isoFileNow() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
}

func loadPromptConfig(repoRoot: URL, wikiRoot: URL) throws -> PromptConfig {
    let promptPath = repoRoot.appendingPathComponent("prompts").appendingPathComponent(promptFileName)
    let promptTemplate = try loadRequiredTextFile(promptPath, name: promptFileName)
    let repoRootPath = repoRoot.path
    let wikiRootPath = wikiRoot.path
    let systemPrompt = promptTemplate
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "[WISP_REPO_ROOT]", with: repoRootPath)
        .replacingOccurrences(of: "[WISP_WIKI_ROOT]", with: wikiRootPath)
        + "\n\n"
        + formatStatusBlock(wikiRoot: wikiRootPath, now: Date())

    return PromptConfig(
        systemPrompt: systemPrompt,
        systemPromptSource: promptPath.path
    )
}

func runInit(config: InitConfig) throws {
    let fm = FileManager.default
    let root = config.targetRoot
    let repoConfigDir = config.configPath.deletingLastPathComponent()
    let schemaPath = wikiSchemaPath(wikiRoot: root)

    try fm.createDirectory(at: repoConfigDir, withIntermediateDirectories: true)
    try renderWorkspaceConfig(repoRoot: config.repoRoot, wikiRoot: root).write(
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
    try fm.createDirectory(at: root.appendingPathComponent("tasks"), withIntermediateDirectories: true)

    print("wiki workspace ready at \(root.path)")
    print("config updated: \(config.configPath.path)")
}

func renderWorkspaceConfig(repoRoot: URL, wikiRoot: URL?) -> String {
    let wikiRootPath = wikiRoot?.path ?? ""
    return [
        "# Wisp workspace configuration",
        "paths:",
        "  repo_root: \(quoteYAMLScalar(repoRoot.path))",
        "  wiki_root: \(quoteYAMLScalar(wikiRootPath))",
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
        "# Tag Guide",
        "",
        "Use section tags in headings, not file-level metadata.",
        "Prefer short namespaced tags such as:",
        "- #person/sean",
        "- #project/wisp",
        "- #topic/oauth",
        "- #task/followup",
        "",
        "Suggested file prelude for every note and task:",
        "# Title",
        "created: YYYY-MM-DD",
        "modified: YYYY-MM-DD",
        "summary: one line summary",
        "artifacts: none or [[path]], [[path]]",
        "Store raw workspace files under artifacts/ and link them as [[artifacts/...]].",
        "",
        "Tasks may add:",
        "status: open",
        "due: none",
        "time: none",
        "place: none"
    ].joined(separator: "\n") + "\n"
}

func formatStatusBlock(wikiRoot: String, now: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let trimmedWikiRoot = wikiRoot.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedWikiRoot.isEmpty {
        return "Status:\n- date: \(formatter.string(from: now))"
    }
    return "Status:\n- date: \(formatter.string(from: now))\n- wiki: \(trimmedWikiRoot)"
}

func resolveWritableWikiPath(rawPath: String, wikiRoot: URL) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AppError.io("path must be non-empty")
    }
    let resolved: URL
    if trimmed.hasPrefix("/") {
        resolved = URL(fileURLWithPath: trimmed).standardizedFileURL
    } else {
        resolved = wikiRoot.appendingPathComponent(trimmed).standardizedFileURL
    }
    guard isPathWithinRoot(resolved, root: wikiRoot) else {
        throw AppError.io("refusing write outside wiki root: \(wikiRoot.path)")
    }
    return resolved
}

func relativeWikiPath(_ url: URL, wikiRoot: URL) -> String {
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

func wikiSchemaPath(wikiRoot: URL) -> URL {
    wikiRoot.appendingPathComponent("schema.md").standardizedFileURL
}

func todayString() -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: Date())
}

func normalizeSummaryLine(_ summary: String) -> String {
    summary
        .replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func normalizeArtifactReference(_ value: String) -> String? {
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

func renderArtifactsLine(_ artifacts: [String]) -> String {
    var seen = Set<String>()
    let cleaned = artifacts
        .compactMap(normalizeArtifactReference)
        .filter { seen.insert($0).inserted }
    if cleaned.isEmpty { return "artifacts: none" }
    return "artifacts: " + cleaned.joined(separator: ", ")
}

func slugifyFileStem(_ title: String) -> String {
    let lowered = title.lowercased()
    let pieces = lowered.split { !$0.isLetter && !$0.isNumber }
    let slug = pieces.map(String.init).filter { !$0.isEmpty }.joined(separator: "-")
    return slug.isEmpty ? "untitled" : slug
}

func renderEntryDocument(title: String, summary: String, artifacts: [String], content: String, extraLines: [String] = []) -> String {
    let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
    let today = todayString()
    var lines = [
        "# \(title.trimmingCharacters(in: .whitespacesAndNewlines))",
        "created: \(today)",
        "modified: \(today)",
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

func normalizedMetadataValue(_ value: String?, defaultValue: String) -> String {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? defaultValue : trimmed
}

func renderNoteDocument(title: String, summary: String, artifacts: [String], content: String) -> String {
    renderEntryDocument(title: title, summary: summary, artifacts: artifacts, content: content)
}

func renderTaskDocument(title: String, summary: String, artifacts: [String], content: String, due: String?, time: String?, place: String?, status: String?) -> String {
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
        ]
    )
}

func writeNewDocument(document: String, explicitPath: String?, defaultRelativePath: String, config: CLIConfig) throws -> String {
    let target = try resolveNewEntryPath(
        explicitPath: explicitPath,
        defaultRelativePath: defaultRelativePath,
        wikiRoot: config.wikiRoot
    )
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try document.write(to: target, atomically: true, encoding: .utf8)
    return relativeWikiPath(target, wikiRoot: config.wikiRoot)
}

func createNoteFile(title: String, summary: String, content: String, artifacts: [String], explicitPath: String?, config: CLIConfig) throws -> String {
    let document = renderNoteDocument(title: title, summary: summary, artifacts: artifacts, content: content)
    return try writeNewDocument(
        document: document,
        explicitPath: explicitPath,
        defaultRelativePath: slugifyFileStem(title) + ".md",
        config: config
    )
}

func createTaskFile(title: String, summary: String, content: String, artifacts: [String], due: String?, time: String?, place: String?, status: String?, explicitPath: String?, config: CLIConfig) throws -> String {
    let document = renderTaskDocument(
        title: title,
        summary: summary,
        artifacts: artifacts,
        content: content,
        due: due,
        time: time,
        place: place,
        status: status
    )
    return try writeNewDocument(
        document: document,
        explicitPath: explicitPath,
        defaultRelativePath: "tasks/" + slugifyFileStem(title) + ".md",
        config: config
    )
}

func resolveNewEntryPath(explicitPath: String?, defaultRelativePath: String, wikiRoot: URL) throws -> URL {
    let target = try resolveWritableWikiPath(rawPath: explicitPath ?? defaultRelativePath, wikiRoot: wikiRoot)
    if FileManager.default.fileExists(atPath: target.path) {
        throw AppError.io("refusing to overwrite existing file at \(relativeWikiPath(target, wikiRoot: wikiRoot))")
    }
    return target
}

func touchModifiedLineIfPresent(_ content: String) -> String {
    let lines = content.components(separatedBy: .newlines)
    guard !lines.isEmpty else { return content }
    var updated = lines
    let maxIndex = min(updated.count, 12)
    for index in 0..<maxIndex where updated[index].hasPrefix("modified:") {
        updated[index] = "modified: \(todayString())"
        return updated.joined(separator: "\n")
    }
    return content
}

struct ResolvedWorkspaceConfig {
    let configPath: URL?
    let values: WorkspaceConfigValues
    let repoRoot: URL
    let wikiRoot: URL?
}

func resolveWorkspaceConfig(startingAt: URL) throws -> ResolvedWorkspaceConfig {
    let defaultRoot = startingAt.standardizedFileURL
    if let configPath = findWorkspaceConfigPath(startingAt: defaultRoot) {
        let configRoot = configPath.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        let rawValues = try parseSimpleYAMLConfig(at: configPath)
        let values = try makeWorkspaceConfigValues(rawValues: rawValues, configRoot: configRoot)
        return ResolvedWorkspaceConfig(
            configPath: configPath,
            values: values,
            repoRoot: values.repoRoot,
            wikiRoot: values.wikiRoot
        )
    }

    let values = WorkspaceConfigValues(
        repoRoot: defaultRoot,
        wikiRoot: nil,
        model: nil,
        reasoningEffort: nil,
        baseURL: nil
    )
    return ResolvedWorkspaceConfig(
        configPath: nil,
        values: values,
        repoRoot: values.repoRoot,
        wikiRoot: values.wikiRoot
    )
}

func findWorkspaceConfigPath(startingAt: URL) -> URL? {
    var current = startingAt.standardizedFileURL
    let fm = FileManager.default
    while true {
        let candidate = current.appendingPathComponent(workspaceConfigRelativePath)
        if fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path {
            return nil
        }
        current = parent
    }
}

func makeWorkspaceConfigValues(rawValues: [String: String], configRoot: URL) throws -> WorkspaceConfigValues {
    let resolvedRepoRoot = (try resolveConfiguredURL(
        rawValue: rawValues["paths.repo_root"],
        baseDirectory: configRoot,
        fieldName: "repo_root",
        defaultURL: configRoot
    )) ?? configRoot
    let resolvedWikiRoot = try resolveConfiguredURL(
        rawValue: rawValues["paths.wiki_root"],
        baseDirectory: resolvedRepoRoot,
        fieldName: "wiki_root",
        defaultURL: nil
    )
    return WorkspaceConfigValues(
        repoRoot: resolvedRepoRoot,
        wikiRoot: resolvedWikiRoot,
        model: normalizeConfigValue(rawValues["model.name"]),
        reasoningEffort: normalizeConfigValue(rawValues["model.reasoning_effort"]),
        baseURL: normalizeConfigValue(rawValues["model.base_url"])
    )
}

func resolveConfiguredURL(rawValue: String?, baseDirectory: URL, fieldName: String, defaultURL: URL?) throws -> URL? {
    guard let rawValue = normalizeConfigValue(rawValue) else {
        return defaultURL?.standardizedFileURL
    }
    let url: URL
    if rawValue.hasPrefix("/") {
        url = URL(fileURLWithPath: rawValue)
    } else {
        url = baseDirectory.appendingPathComponent(rawValue)
    }
    let standardized = url.standardizedFileURL
    guard FileManager.default.fileExists(atPath: standardized.path) else {
        throw AppError.io("Configured \(fieldName) does not exist: \(standardized.path)")
    }
    return standardized
}

func parseSimpleYAMLConfig(at url: URL) throws -> [String: String] {
    let text = try loadRequiredTextFile(url, name: url.lastPathComponent)
    var values: [String: String] = [:]
    var sectionStack: [(indent: Int, key: String)] = []

    for rawLine in text.components(separatedBy: .newlines) {
        if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
            continue
        }
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            continue
        }

        let indent = rawLine.prefix { $0 == " " }.count
        let line = trimmed
        if line.isEmpty || line.hasPrefix("#") {
            continue
        }
        guard let separator = line.firstIndex(of: ":") else {
            throw AppError.io("Invalid config line in \(url.path): \(rawLine)")
        }
        while let last = sectionStack.last, last.indent >= indent {
            sectionStack.removeLast()
        }

        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let valueStart = line.index(after: separator)
        let value = String(line[valueStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        let fullKeyPrefix = sectionStack.map(\.key)
        let fullKey = (fullKeyPrefix + [key]).joined(separator: ".")
        if value.isEmpty {
            sectionStack.append((indent: indent, key: key))
            continue
        }
        values[fullKey] = unquoteYAMLScalar(value)
    }
    return values
}

func unquoteYAMLScalar(_ value: String) -> String {
    guard value.count >= 2 else { return value }
    if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
        let start = value.index(after: value.startIndex)
        let end = value.index(before: value.endIndex)
        return String(value[start..<end])
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
    return value
}

func normalizeConfigValue(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func makeAbsoluteURL(path: String) -> URL {
    let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.hasPrefix("/") {
        return URL(fileURLWithPath: raw).standardizedFileURL
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(raw)
        .standardizedFileURL
}

func promptForWikiRoot() throws -> URL {
    print("wiki root is not configured.")
    print("enter wiki directory (absolute path preferred): ", terminator: "")
    guard let line = readLine() else {
        throw AppError.io("No wiki directory provided.")
    }
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AppError.io("Wiki directory cannot be empty.")
    }
    return makeAbsoluteURL(path: trimmed)
}

func loadRequiredTextFile(_ url: URL, name: String) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AppError.io("Missing file: \(name) at \(url.path)")
    }
    guard let data = FileManager.default.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not read file: \(name) at \(url.path)")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        throw AppError.io("File is empty: \(name) at \(url.path)")
    }
    return text
}

func logEvent(type: String, payload: [String: String], config: CLIConfig) throws {
    try appendLog(type: type, payload: payload, writer: config.logWriter)
    guard config.verbose else { return }
    let lines = formatVerboseLines(type: type, payload: payload)
    for line in lines {
        print(line)
    }
}

func formatVerboseLines(type: String, payload: [String: String]) -> [String] {
    switch type {
    case "step":
        let name = payload["name"] ?? "unknown"
        let state = payload["state"] ?? "unknown"
        if let duration = payload["duration_ms"], state == "finished" {
            return ["[verbose] step: \(name) finished in \(duration)ms"]
        }
        return ["[verbose] step: \(name) \(state)"]
    case "model_call":
        let duration = payload["duration_ms"] ?? "?"
        let toolCalls = payload["tool_calls"] ?? "0"
        let messages = payload["assistant_messages"] ?? "0"
        return ["[verbose] model_call: duration_ms=\(duration), tool_calls=\(toolCalls), assistant_messages=\(messages)"]
    case "model_response":
        let continueTurn = payload["continue_turn"] ?? "false"
        let message = payload["message"] ?? ""
        let scratchpad = payload["scratchpad"] ?? ""
        return [
            "[verbose] model_response.continue_turn: \(continueTurn)",
            "[verbose] model_response.message:",
            indentMultiline(message),
            "[verbose] model_response.scratchpad:",
            indentMultiline(scratchpad)
        ]
    case "tool_call":
        return [
            "[verbose] tool_call: \(payload["name"] ?? "unknown")",
            indentMultiline(payload["arguments"] ?? "")
        ]
    case "tool_result":
        let status = payload["status_code"] ?? "?"
        let runtime = payload["runtime_duration_ms"] ?? "?"
        var lines = ["[verbose] tool_result: status_code=\(status), runtime_duration_ms=\(runtime)"]
        if let truncated = payload["truncated"], truncated == "true" {
            let totalBytes = payload["total_bytes"] ?? "?"
            let artifactPath = payload["artifact_path"] ?? ""
            lines.append("[verbose] tool_result.truncated: true (total_bytes=\(totalBytes))")
            if !artifactPath.isEmpty {
                lines.append("[verbose] tool_result.artifact_path: \(artifactPath)")
            }
        }
        return lines
    default:
        return []
    }
}
