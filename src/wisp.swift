import Foundation
import CryptoKit
import Darwin

struct CLIConfig {
    let verbose: Bool
    let logPath: URL
    let codex: CodexSettings
    let promptConfig: PromptConfig
    let sessionID: String
}

struct TurnOutput: Codable {
    let plan: String
    let message: String
    let code: String
    let is_complete: Bool
}

struct LuaRunOutput: Codable {
    let status_code: Int
    let stdout: String
    let stderr: String
    let truncation_mode: String
    let runtime_duration_ms: Int
}

struct ToolResultForModel: Codable {
    let status_code: Int
    let text: String
    let runtime_duration_ms: Int
    let truncated: Bool
    let total_bytes: Int
    let artifact_path: String?
}

struct BashHelperOutput: Codable {
    let status_code: Int
    let stdout_b64: String
    let stderr_b64: String
}

struct CacheStats {
    let inputTokens: Int
    let cachedTokens: Int
    let percent: Double
}

struct ModelCallOutput {
    let turn: TurnOutput
    let cacheStats: CacheStats?
    let promptCacheKey: String?
}

struct DecodedModelText {
    let text: String
    let cacheStats: CacheStats?
}

struct SessionEvent: Codable {
    let timestamp: String
    let type: String
    let payload: [String: String]
}

struct CodexSettings {
    let baseURL: String
    let authFile: URL
    let model: String
    let reasoningEffort: String
}

struct PromptConfig {
    let systemPrompt: String
    let systemPromptSource: String
}

struct ResponsesRequest: Encodable {
    let model: String
    let instructions: String
    let prompt_cache_key: String
    let store: Bool
    let stream: Bool
    let reasoning: ResponsesReasoning
    let input: [ResponseInputItem]
    let include: [String]
    let text: ResponsesTextConfig
}

struct ResponsesReasoning: Encodable {
    let effort: String
    let summary: String
}

struct ResponsesTextConfig: Encodable {
    let format: ResponsesTextFormat
}

struct ResponsesTextFormat: Encodable {
    let type: String
    let name: String
    let strict: Bool
    let schema: ResponseSchema
}

struct ResponseSchema: Encodable {
    let type: String
    let properties: [String: ResponseSchemaProperty]
    let required: [String]
    let additionalProperties: Bool
}

struct ResponseSchemaProperty: Encodable {
    let type: String
}

struct ResponseMessageContent: Encodable {
    let type: String
    let text: String
}

struct LuaExecArguments: Encodable {
    let name: String
    let args: String
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
    case luaUnavailable
    case io(String)

    var description: String {
        switch self {
        case .missingOAuthToken:
            return "Codex auth file does not contain an access token."
        case .invalidModelResponse(let message):
            return "Invalid model response: \(message)"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .luaUnavailable:
            return "Lua runtime is unavailable. Install `lua` and ensure it is in PATH."
        case .io(let message):
            return "IO error: \(message)"
        }
    }
}

let promptFileName = "prompt.md"
let readOrBashMaxLines = 2_000
let readOrBashMaxBytes = 50 * 1024

@main
struct WispMain {
    static func main() {
        do {
            if try runInternalToolModeIfRequested() {
                return
            }
            let config = try parseArgs()
            try prepareDirectories(for: config.logPath)
            try resetSessionLog(logPath: config.logPath)
            if config.verbose {
                print("[verbose] prompts.system: \(config.promptConfig.systemPromptSource)")
            }
            print("session initialized (previous session archived if present).")
            print("wisp started. Type `exit` to quit and clear session, or `restart` to clear session and continue.")

            while true {
                print("you> ", terminator: "")
                guard let line = readLine() else { break }
                let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if command == "exit" {
                    try resetSessionLog(logPath: config.logPath)
                    print("session ended.")
                    break
                }
                if command == "restart" {
                    try resetSessionLog(logPath: config.logPath)
                    print("session restarted.")
                    continue
                }
                if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                try processUserTurn(line, config: config)
            }
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }
}

func runInternalToolModeIfRequested() throws -> Bool {
    let args = Array(CommandLine.arguments.dropFirst())
    guard let mode = args.first else { return false }
    if mode == "--tool-bash" {
        try runBashHelperMode(args: Array(args.dropFirst()))
        return true
    }
    return false
}

func runBashHelperMode(args: [String]) throws {
    var commandFile: String?
    var timeoutMs = 15_000
    var index = 0
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--command-file":
            index += 1
            guard index < args.count else {
                throw AppError.io("Missing value for --command-file")
            }
            commandFile = args[index]
        case "--timeout-ms":
            index += 1
            guard index < args.count else {
                throw AppError.io("Missing value for --timeout-ms")
            }
            timeoutMs = max(1, Int(args[index]) ?? timeoutMs)
        default:
            throw AppError.io("Unknown --tool-bash argument: \(arg)")
        }
        index += 1
    }

    guard let commandFile else {
        throw AppError.io("--tool-bash requires --command-file")
    }
    let command = try String(contentsOfFile: commandFile, encoding: .utf8)
    let result = try runBashCommand(command: command, timeoutMs: timeoutMs)
    let encoded = try encodeJSON(
        BashHelperOutput(
            status_code: result.statusCode,
            stdout_b64: Data(result.stdout.utf8).base64EncodedString(),
            stderr_b64: Data(result.stderr.utf8).base64EncodedString()
        )
    )
    print(encoded)
}

func runBashCommand(command: String, timeoutMs: Int) throws -> (statusCode: Int, stdout: String, stderr: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]

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

    let start = Date()
    var didTimeout = false
    var sentTerminate = false
    var terminateAt: Date?
    while process.isRunning {
        if !didTimeout {
            let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
            if elapsedMs >= timeoutMs {
                didTimeout = true
                sentTerminate = true
                terminateAt = Date()
                process.terminate()
            }
        } else if sentTerminate, let terminateAt {
            let drainWindowMs = Int(Date().timeIntervalSince(terminateAt) * 1000)
            if drainWindowMs >= 1500 {
                break
            }
        }
        usleep(50_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
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
    let args = CommandLine.arguments.dropFirst()
    var verbose = false
    let logPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".wisp/session.jsonl")
    let promptsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("prompts")
    var index = args.startIndex

    while index < args.endIndex {
        let arg = args[index]
        switch arg {
        case "--verbose":
            verbose = true
            index = args.index(after: index)
        default:
            throw AppError.io("Unknown argument: \(arg)")
        }
    }

    let codex = resolveCodexSettings()
    let promptConfig = try loadPromptConfig(promptsDir: promptsDir)
    return CLIConfig(
        verbose: verbose,
        logPath: logPath,
        codex: codex,
        promptConfig: promptConfig,
        sessionID: UUID().uuidString.lowercased()
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

func processUserTurn(_ userMessage: String, config: CLIConfig) throws {
    try logEvent(type: "user_message", payload: ["text": userMessage], config: config)

    while true {
        try logEvent(type: "step", payload: ["name": "construct_context", "state": "started"], config: config)
        let replayResult = try timed {
            try buildSessionInputItems(logPath: config.logPath)
        }
        try logEvent(
            type: "step",
            payload: ["name": "construct_context", "state": "finished", "duration_ms": String(replayResult.durationMs)],
            config: config
        )
        try logEvent(
            type: "context_constructed",
            payload: [
                "events": String(replayResult.value.eventCount),
                "duration_ms": String(replayResult.durationMs)
            ],
            config: config
        )

        try logEvent(type: "step", payload: ["name": "model_call", "state": "started"], config: config)
        let modelResult = try timed {
            try callModel(
                replayInputItems: replayResult.value.inputItems,
                promptConfig: config.promptConfig,
                codex: config.codex,
                sessionID: config.sessionID
            )
        }
        try logEvent(
            type: "step",
            payload: ["name": "model_call", "state": "finished", "duration_ms": String(modelResult.durationMs)],
            config: config
        )
        var modelCallPayload: [String: String] = [
            "duration_ms": String(modelResult.durationMs)
        ]
        if let key = modelResult.value.promptCacheKey, !key.isEmpty {
            modelCallPayload["prompt_cache_key"] = key
        }
        if let cache = modelResult.value.cacheStats {
            modelCallPayload["cache_percent"] = formatPercent(cache.percent)
            modelCallPayload["cache_cached_tokens"] = String(cache.cachedTokens)
            modelCallPayload["cache_input_tokens"] = String(cache.inputTokens)
        }
        try logEvent(type: "model_call", payload: modelCallPayload, config: config)

        var turn = modelResult.value.turn
        if turn.is_complete && !turn.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turn = TurnOutput(
                plan: turn.plan,
                message: turn.message,
                code: turn.code,
                is_complete: false
            )
        }

        let modelPayload: [String: String] = [
            "plan": turn.plan,
            "message": turn.message,
            "code": turn.code,
            "is_complete": String(turn.is_complete)
        ]
        try logEvent(type: "model_response", payload: modelPayload, config: config)

        let trimmedCode = turn.code.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedCode.isEmpty {
            print("assistant> \(turn.message)")
            return
        }

        let callID = "call_\(UUID().uuidString.lowercased())"
        try logEvent(type: "tool_call", payload: ["code": turn.code, "call_id": callID], config: config)
        try logEvent(type: "step", payload: ["name": "lua_runtime", "state": "started"], config: config)
        let luaStart = Date()
        var luaOutput = LuaRunOutput(
            status_code: 1,
            stdout: "",
            stderr: "",
            truncation_mode: "head",
            runtime_duration_ms: 0
        )
        var luaDurationMs = 0
        do {
            let luaResult = try timed {
                try executeLua(code: turn.code)
            }
            luaOutput = luaResult.value
            luaDurationMs = luaResult.durationMs
            try logEvent(
                type: "step",
                payload: ["name": "lua_runtime", "state": "finished", "duration_ms": String(luaDurationMs)],
                config: config
            )
        } catch {
            luaDurationMs = max(0, Int(Date().timeIntervalSince(luaStart) * 1000))
            try logEvent(
                type: "step",
                payload: ["name": "lua_runtime", "state": "failed", "duration_ms": String(luaDurationMs)],
                config: config
            )
            luaOutput = LuaRunOutput(
                status_code: 1,
                stdout: "",
                stderr: "Lua runtime error: \(error)",
                truncation_mode: "head",
                runtime_duration_ms: luaDurationMs
            )
        }
        let modelToolResult = try buildToolResultForModel(from: luaOutput, logPath: config.logPath)
        let toolResultString = try encodeReplayToolResult(modelToolResult)
        try logEvent(
            type: "tool_result",
            payload: [
                "result": toolResultString,
                "status_code": String(modelToolResult.status_code),
                "runtime_duration_ms": String(modelToolResult.runtime_duration_ms),
                "call_id": callID,
                "truncated": String(modelToolResult.truncated),
                "total_bytes": String(modelToolResult.total_bytes),
                "artifact_path": modelToolResult.artifact_path ?? ""
            ],
            config: config
        )
    }
}

func callModel(
    replayInputItems: [ResponseInputItem],
    promptConfig: PromptConfig,
    codex: CodexSettings,
    sessionID: String
) throws -> ModelCallOutput {
    let token = try loadCodexOAuthToken(authFile: codex.authFile)
    let url = try CodexOAuth.resolveResponsesURL(baseURL: codex.baseURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let instructions = promptConfig.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptCacheKey = buildPromptCacheKey(sessionID: sessionID)
    let headers = try CodexOAuth.buildSSEHeaders(token: token, sessionID: promptCacheKey)
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }

    let payload = ResponsesRequest(
        model: codex.model,
        instructions: instructions,
        prompt_cache_key: promptCacheKey,
        store: false,
        stream: true,
        reasoning: ResponsesReasoning(
            effort: codex.reasoningEffort,
            summary: "auto"
        ),
        input: replayInputItems,
        include: ["reasoning.encrypted_content"],
        text: ResponsesTextConfig(
            format: ResponsesTextFormat(
                type: "json_schema",
                name: "wisp_turn_output",
                strict: true,
                schema: makeResponseSchema()
            )
        )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    request.httpBody = try encoder.encode(payload)
    let responseData = try httpRequest(request)
    let decoded = try decodeModelText(from: responseData)
    guard let data = decoded.text.data(using: .utf8) else {
        throw AppError.invalidModelResponse("Model text was not utf8")
    }
    do {
        let turn = try JSONDecoder().decode(TurnOutput.self, from: data)
        return ModelCallOutput(
            turn: turn,
            cacheStats: decoded.cacheStats,
            promptCacheKey: promptCacheKey
        )
    } catch {
        throw AppError.invalidModelResponse("Could not decode TurnOutput. Raw text: \(decoded.text)")
    }
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

func executeLua(code: String) throws -> LuaRunOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    let runtimePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("scripts/lua_runtime.lua").path
    process.arguments = ["lua", runtimePath]
    var runtimeEnv = ProcessInfo.processInfo.environment
    runtimeEnv["WISP_CHAT_HELPER_BIN"] = CommandLine.arguments[0]
    runtimeEnv["WISP_WORKSPACE_ROOT"] = FileManager.default.currentDirectoryPath
    process.environment = runtimeEnv

    let inputPipe = Pipe()
    let outputPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    // Merge stderr into stdout and drain continuously to avoid pipe-buffer deadlocks.
    process.standardError = outputPipe

    do {
        try process.run()
    } catch {
        throw AppError.luaUnavailable
    }

    if let data = code.data(using: .utf8) {
        inputPipe.fileHandleForWriting.write(data)
    }
    inputPipe.fileHandleForWriting.closeFile()

    let timeoutMs = Int(ProcessInfo.processInfo.environment["WISP_LUA_TIMEOUT_MS"] ?? "") ?? 15_000
    var didTimeout = false
    let timeoutTask = DispatchWorkItem {
        guard process.isRunning else { return }
        didTimeout = true
        process.terminate()
        usleep(200_000)
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
    DispatchQueue.global(qos: .userInitiated).asyncAfter(
        deadline: .now() + .milliseconds(timeoutMs),
        execute: timeoutTask
    )

    let merged = outputPipe.fileHandleForReading.readDataToEndOfFile()
    timeoutTask.cancel()
    process.waitUntilExit()
    guard let text = String(data: merged, encoding: .utf8) else {
        throw AppError.invalidModelResponse("Lua output was not utf8")
    }

    if didTimeout {
        let preview = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = preview.isEmpty ? "" : " Output before timeout: \(preview)"
        throw AppError.requestFailed("Lua runtime timed out after \(timeoutMs)ms.\(suffix)")
    }

    if process.terminationStatus != 0 {
        throw AppError.requestFailed("Lua process failed: \(text)")
    }

    guard let data = text.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
        throw AppError.invalidModelResponse("Lua json output was invalid utf8")
    }
    do {
        return try JSONDecoder().decode(LuaRunOutput.self, from: data)
    } catch {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allLines = trimmed.components(separatedBy: .newlines)
        for i in stride(from: allLines.count - 1, through: 0, by: -1) {
            let candidate = allLines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            guard candidate.hasPrefix("{"), candidate.hasSuffix("}") else { continue }
            if let lineData = candidate.data(using: .utf8),
               var parsed = try? JSONDecoder().decode(LuaRunOutput.self, from: lineData) {
                let prefix = allLines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !prefix.isEmpty {
                    let mergedStdout = parsed.stdout.isEmpty ? prefix : prefix + "\n" + parsed.stdout
                    parsed = LuaRunOutput(
                        status_code: parsed.status_code,
                        stdout: mergedStdout,
                        stderr: parsed.stderr,
                        truncation_mode: parsed.truncation_mode,
                        runtime_duration_ms: parsed.runtime_duration_ms
                    )
                }
                return parsed
            }
        }
        throw AppError.invalidModelResponse("Could not decode Lua output. Raw: \(text)")
    }
}

func httpRequest(_ request: URLRequest) throws -> Data {
    let semaphore = DispatchSemaphore(value: 0)
    final class RequestState: @unchecked Sendable {
        let lock = NSLock()
        var resultData: Data?
        var resultError: Error?
        var statusCode: Int?
    }
    let state = RequestState()

    URLSession.shared.dataTask(with: request) { data, response, error in
        defer { semaphore.signal() }
        state.lock.lock()
        defer { state.lock.unlock() }
        if let error {
            state.resultError = error
            return
        }
        if let http = response as? HTTPURLResponse {
            state.statusCode = http.statusCode
        }
        state.resultData = data
    }.resume()

    semaphore.wait()
    if let resultError = state.resultError {
        throw AppError.requestFailed(resultError.localizedDescription)
    }
    guard let data = state.resultData else {
        throw AppError.requestFailed("No data from API")
    }
    guard let statusCode = state.statusCode else {
        throw AppError.requestFailed("No HTTP status code from API")
    }
    guard (200..<300).contains(statusCode) else {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        throw AppError.requestFailed("HTTP \(statusCode): \(body)")
    }
    return data
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

func extractOutputText(from responseObject: [String: Any]) -> String {
    if let text = nonEmptyText(responseObject["output_text"]) ?? nonEmptyText(responseObject["text"]) {
        return text
    }
    guard let output = responseObject["output"] as? [[String: Any]] else {
        return ""
    }
    for item in output {
        if let text = nonEmptyText(item["text"]) {
            return text
        }
        guard let content = item["content"] as? [[String: Any]] else {
            continue
        }
        for part in content {
            if let text = nonEmptyText(part["output_text"]) ?? nonEmptyText(part["text"]) {
                return text
            }
        }
    }
    return ""
}

func extractModelText(from responseObject: [String: Any]) -> String? {
    let text = extractOutputText(from: responseObject)
    return text.isEmpty ? nil : text
}

func decodeModelText(from responseData: Data) throws -> DecodedModelText {
    if let json = try? JSONSerialization.jsonObject(with: responseData, options: []),
       let obj = json as? [String: Any] {
        if let text = extractModelText(from: obj) {
            return DecodedModelText(text: text, cacheStats: extractCacheStats(from: obj))
        }
    }

    guard let streamText = String(data: responseData, encoding: .utf8) else {
        throw AppError.invalidModelResponse("Response was neither JSON nor utf8 SSE")
    }
    var collectedOutput = ""
    var currentDataLines: [String] = []
    var cacheStats: CacheStats?
    var streamFailureMessage: String?
    var lastCompletedResponsePreview: String?
    var lastUnparsedEventPreview: String?

    func flushEvent() throws -> (done: Bool, output: String?) {
        guard !currentDataLines.isEmpty else { return (false, nil) }
        let payload = currentDataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        currentDataLines.removeAll(keepingCapacity: true)
        if payload.isEmpty { return (false, nil) }
        if payload == "[DONE]" { return (true, nil) }

        guard let eventData = payload.data(using: .utf8),
              let eventJSON = try? JSONSerialization.jsonObject(with: eventData, options: []),
              let event = eventJSON as? [String: Any],
              let eventType = event["type"] as? String else {
            lastUnparsedEventPreview = compactText(payload, limit: 1200)
            return (false, nil)
        }

        if eventType == "response.output_text.delta", let delta = event["delta"] as? String {
            collectedOutput += delta
            return (false, nil)
        }
        if eventType == "response.failed" || eventType == "error" {
            if let errorObj = event["error"] as? [String: Any],
               let message = errorObj["message"] as? String,
               !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                streamFailureMessage = message
            } else if let message = event["message"] as? String,
                      !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                streamFailureMessage = message
            } else {
                streamFailureMessage = "Responses stream failed with event type \(eventType)"
            }
            return (true, nil)
        }
        if (eventType == "response.output_text.done" || eventType == "response.text.done"),
           let text = event["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            collectedOutput = text
            return (false, nil)
        }
        if eventType == "response.completed" {
            if let responseObj = event["response"] as? [String: Any] {
                cacheStats = extractCacheStats(from: responseObj)
                let final = extractModelText(from: responseObj)
                lastCompletedResponsePreview = compactText(serializeJSONObject(responseObj), limit: 1200)
                if let final {
                    return (true, final)
                }
            }
            return (true, nil)
        }
        return (false, nil)
    }

    for raw in streamText.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            let result = try flushEvent()
            if result.done {
                let final = (result.output ?? collectedOutput).trimmingCharacters(in: .whitespacesAndNewlines)
                if !final.isEmpty {
                    return DecodedModelText(text: final, cacheStats: cacheStats)
                }
                break
            }
            continue
        }
        if line.hasPrefix("data:") {
            currentDataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
    }
    let tail = try flushEvent()
    if tail.done {
        let final = (tail.output ?? collectedOutput).trimmingCharacters(in: .whitespacesAndNewlines)
        if !final.isEmpty {
            return DecodedModelText(text: final, cacheStats: cacheStats)
        }
    }

    if let final = nonEmptyText(collectedOutput) {
        return DecodedModelText(text: final, cacheStats: cacheStats)
    }
    if let streamFailureMessage, !streamFailureMessage.isEmpty {
        throw AppError.invalidModelResponse("Responses stream failed: \(streamFailureMessage)")
    }
    var details: [String] = []
    if let lastCompletedResponsePreview, !lastCompletedResponsePreview.isEmpty {
        details.append("response.completed preview: \(lastCompletedResponsePreview)")
    }
    if let lastUnparsedEventPreview, !lastUnparsedEventPreview.isEmpty {
        details.append("unparsed event preview: \(lastUnparsedEventPreview)")
    }
    let streamPreview = compactText(streamText, limit: 1200)
    if !streamPreview.isEmpty {
        details.append("stream preview: \(streamPreview)")
    }
    if details.isEmpty {
        throw AppError.invalidModelResponse("Could not extract output text from streamed response")
    }
    throw AppError.invalidModelResponse("Could not extract output text from streamed response. " + details.joined(separator: " | "))
}

func appendLog(type: String, payload: [String: String], logPath: URL) throws {
    let event = SessionEvent(timestamp: isoNow(), type: type, payload: payload)
    let data = try JSONEncoder().encode(event)
    guard var line = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not encode log event")
    }
    line.append("\n")
    if let fileHandle = try? FileHandle(forWritingTo: logPath) {
        try fileHandle.seekToEnd()
        if let lineData = line.data(using: .utf8) {
            fileHandle.write(lineData)
        }
        try fileHandle.close()
    } else {
        try line.write(to: logPath, atomically: true, encoding: .utf8)
    }
}

func buildSessionInputItems(logPath: URL) throws -> (inputItems: [ResponseInputItem], eventCount: Int) {
    guard let data = FileManager.default.contents(atPath: logPath.path),
          let content = String(data: data, encoding: .utf8) else {
        return ([], 0)
    }
    let lines = content.split(separator: "\n")
    var inputItems: [ResponseInputItem] = []
    let replayTypes: Set<String> = ["user_message", "model_response", "tool_call", "tool_result"]
    var replayEventCount = 0
    for line in lines {
        guard let rowData = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(SessionEvent.self, from: rowData) else {
            continue
        }
        guard replayTypes.contains(event.type) else {
            continue
        }
        replayEventCount += 1
        switch event.type {
        case "user_message":
            let text = event.payload["text"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                inputItems.append(buildInputTextMessageItem(role: "user", text: text))
            }
        case "model_response":
            let text = try buildTurnReplayText(payload: event.payload)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputItems.append(buildAssistantOutputMessageItem(text: text))
            }
        case "tool_call":
            let code = event.payload["code"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if code.isEmpty { continue }
            let callID = event.payload["call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if callID.isEmpty { continue }
            let arguments = try encodeJSON(LuaExecArguments(name: "lua.exec", args: code))
            inputItems.append(.functionCall(callID: callID, name: "wisp_code", arguments: arguments))
        case "tool_result":
            let output = event.payload["result"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if output.isEmpty { continue }
            let callID = event.payload["call_id"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !callID.isEmpty {
                inputItems.append(.functionCallOutput(callID: callID, output: output))
            } else {
                inputItems.append(buildAssistantOutputMessageItem(text: "Tool result: \(output)"))
            }
        default:
            continue
        }
    }
    return (inputItems, replayEventCount)
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    guard let string = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not encode JSON text")
    }
    return string
}

func encodeReplayToolResult(_ value: ToolResultForModel) throws -> String {
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

func makeResponseSchema() -> ResponseSchema {
    ResponseSchema(
        type: "object",
        properties: [
            "plan": ResponseSchemaProperty(type: "string"),
            "message": ResponseSchemaProperty(type: "string"),
            "code": ResponseSchemaProperty(type: "string"),
            "is_complete": ResponseSchemaProperty(type: "boolean")
        ],
        required: ["plan", "message", "code", "is_complete"],
        additionalProperties: false
    )
}

func resolveCodexSettings() -> CodexSettings {
    let env = ProcessInfo.processInfo.environment
    let home = env["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
    let authFile = URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")

    return CodexSettings(
        baseURL: "https://chatgpt.com/backend-api/codex",
        authFile: authFile,
        model: "gpt-5.4-mini",
        reasoningEffort: "medium"
    )
}

func indentMultiline(_ text: String) -> String {
    text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { "  \($0)" }
        .joined(separator: "\n")
}

func extractCacheStats(from responseObject: [String: Any]) -> CacheStats? {
    guard let usage = responseObject["usage"] as? [String: Any] else {
        return nil
    }
    let inputTokens =
        (usage["input_tokens"] as? Int) ??
        (usage["prompt_tokens"] as? Int) ??
        0
    guard inputTokens > 0 else {
        return nil
    }
    let details =
        (usage["input_tokens_details"] as? [String: Any]) ??
        (usage["prompt_tokens_details"] as? [String: Any]) ??
        [:]
    let cachedTokens = details["cached_tokens"] as? Int ?? 0
    let percent = (Double(cachedTokens) / Double(inputTokens)) * 100.0
    return CacheStats(inputTokens: inputTokens, cachedTokens: cachedTokens, percent: percent)
}

func formatPercent(_ value: Double) -> String {
    String(format: "%.2f%%", value)
}

func compactText(_ text: String, limit: Int) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    let prefix = trimmed.prefix(max(0, limit))
    let omitted = trimmed.count - prefix.count
    return String(prefix) + "... [truncated \(omitted) chars]"
}

func serializeJSONObject(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let text = String(data: data, encoding: .utf8) else {
        return String(describing: object)
    }
    return text
}

func buildTurnReplayText(payload: [String: String]) throws -> String {
    let plan = payload["plan"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let message = payload["message"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let code = payload["code"] ?? ""
    if plan.isEmpty && message.isEmpty && code.isEmpty {
        return ""
    }
    return try encodeJSON(
        TurnOutput(
            plan: plan,
            message: message,
            code: code,
            is_complete: parseBoolString(payload["is_complete"])
        )
    )
}

func parseBoolString(_ value: String?) -> Bool {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "true", "1", "yes":
        return true
    default:
        return false
    }
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

func buildInputTextMessageItem(role: String, text: String) -> ResponseInputItem {
    .message(
        role: role,
        content: [ResponseMessageContent(type: "input_text", text: text)]
    )
}

func buildAssistantOutputMessageItem(text: String) -> ResponseInputItem {
    .message(
        role: "assistant",
        content: [ResponseMessageContent(type: "output_text", text: text)]
    )
}

func buildToolResultForModel(from output: LuaRunOutput, logPath: URL) throws -> ToolResultForModel {
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

    return ToolResultForModel(
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

func loadPromptConfig(promptsDir: URL) throws -> PromptConfig {
    let promptPath = promptsDir.appendingPathComponent(promptFileName)
    let promptTemplate = try loadRequiredTextFile(promptPath, name: promptFileName)
    let systemPrompt = buildSystemPrompt(
        promptTemplate: promptTemplate,
        workingDirectory: FileManager.default.currentDirectoryPath,
        now: Date()
    )

    return PromptConfig(
        systemPrompt: systemPrompt,
        systemPromptSource: promptPath.path
    )
}

func buildSystemPrompt(promptTemplate: String, workingDirectory: String, now: Date) -> String {
    let trimmedTemplate = promptTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    let statusBlock = formatStatusBlock(workingDirectory: workingDirectory, now: now)
    return trimmedTemplate + "\n\n" + statusBlock
}

func formatStatusBlock(workingDirectory: String, now: Date) -> String {
    _ = now
    var lines = ["Status:"]
    let trimmedWorkingDirectory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedWorkingDirectory.isEmpty {
        lines.append("- working directory: \(trimmedWorkingDirectory)")
        lines.append("- writable workspace: \(trimmedWorkingDirectory)")
    }

    return lines.joined(separator: "\n")
}

func loadRequiredTextFile(_ url: URL, name: String) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AppError.io("Missing prompt file: \(name) at \(url.path)")
    }
    guard let data = FileManager.default.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not read prompt file: \(name) at \(url.path)")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        throw AppError.io("Prompt file is empty: \(name) at \(url.path)")
    }
    return text
}

func logEvent(type: String, payload: [String: String], config: CLIConfig) throws {
    try appendLog(type: type, payload: payload, logPath: config.logPath)
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
        var lines: [String] = []
        if let key = payload["prompt_cache_key"], !key.isEmpty {
            lines.append("[verbose] prompt_cache_key: \(key)")
        }
        if let percent = payload["cache_percent"],
           let cached = payload["cache_cached_tokens"],
           let input = payload["cache_input_tokens"] {
            lines.append("[verbose] model_cache: \(percent) (\(cached)/\(input) cached/input tokens)")
            return lines
        }
        lines.append("[verbose] model_cache: unavailable")
        return lines
    case "model_response":
        let plan = payload["plan"] ?? ""
        return [
            "[verbose] model_response.plan:",
            indentMultiline(plan)
        ]
    case "tool_call":
        return [
            "[verbose] tool_call.lua_code:",
            indentMultiline(payload["code"] ?? "")
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
