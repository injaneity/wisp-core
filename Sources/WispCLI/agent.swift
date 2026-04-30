import Foundation
import WispCore
final class ConversationState {
    private(set) var inputItems: [ResponseInputItem] = []

    func reset() {
        inputItems.removeAll(keepingCapacity: true)
    }

    private func record(_ item: ResponseInputItem) {
        inputItems.append(item)
    }

    func appendUserMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record(.message(role: "user", content: [ResponseMessageContent(type: "input_text", text: trimmed)]))
    }

    func appendAssistantMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        record(.message(role: "assistant", content: [ResponseMessageContent(type: "output_text", text: trimmed)]))
    }

    func appendFunctionCall(callID: String, name: String, arguments: String) {
        let trimmedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCallID.isEmpty, !trimmedName.isEmpty else { return }
        record(.functionCall(callID: trimmedCallID, name: trimmedName, arguments: arguments))
    }

    func appendFunctionCallOutput(callID: String, output: String) {
        let trimmedCallID = callID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCallID.isEmpty, !trimmedOutput.isEmpty else { return }
        record(.functionCallOutput(callID: trimmedCallID, output: trimmedOutput))
    }
}

struct ToolCall {
    let callID: String
    let name: String
    let arguments: String
}

private struct ReadToolArguments: Decodable {
    let path: String
    let offset: Int?
    let limit: Int?
}

private struct BashToolArguments: Decodable {
    let command: String
    let timeout: Int?
}

private struct NoteToolArguments: Decodable {
    let title: String
    let summary: String
    let content: String?
    let artifacts: [String]?
    let path: String?
}

private struct TaskToolArguments: Decodable {
    let title: String
    let summary: String
    let content: String?
    let artifacts: [String]?
    let due: String?
    let time: String?
    let place: String?
    let status: String?
    let path: String?
}

private struct EditToolArguments: Decodable {
    struct EditReplacement: Decodable {
        let oldText: String
        let newText: String
    }

    let path: String
    let edits: [EditReplacement]
}

func runAgentLoop(_ userMessage: String, config: CLIConfig) throws {
    try logEvent(type: "user_message", payload: ["text": userMessage], config: config)
    config.conversationState.appendUserMessage(userMessage)

    while true {
        try logEvent(type: "step", payload: ["name": "model_call", "state": "started"], config: config)
        let modelResult = try timed {
            try callModelWithTools(
                replayInputItems: config.conversationState.inputItems,
                promptConfig: config.promptConfig,
                modelBackend: config.modelBackend,
                sessionID: config.sessionID
            )
        }
        try logEvent(
            type: "step",
            payload: ["name": "model_call", "state": "finished", "duration_ms": String(modelResult.durationMs)],
            config: config
        )

        try logEvent(
            type: "model_call",
            payload: [
                "duration_ms": String(modelResult.durationMs),
                "tool_calls": String(modelResult.value.toolCalls.count),
                "assistant_messages": String(modelResult.value.assistantMessages.count)
            ],
            config: config
        )

        let assistantText = modelResult.value.assistantMessages
            .map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        try logEvent(
            type: "model_response",
            payload: [
                "message": assistantText,
                "scratchpad": "",
                "code": "",
                "continue_turn": String(!modelResult.value.toolCalls.isEmpty)
            ],
            config: config
        )
        if !assistantText.isEmpty {
            print("assistant> \(assistantText)")
            config.conversationState.appendAssistantMessage(assistantText)
        }

        guard !modelResult.value.toolCalls.isEmpty else {
            return
        }

        for toolCall in modelResult.value.toolCalls {
            config.conversationState.appendFunctionCall(callID: toolCall.callID, name: toolCall.name, arguments: toolCall.arguments)
            try logEvent(
                type: "tool_call",
                payload: [
                    "call_id": toolCall.callID,
                    "name": toolCall.name,
                    "arguments": compactText(toolCall.arguments, limit: 1_200)
                ],
                config: config
            )
            try logEvent(
                type: "step",
                payload: ["name": "tool_execution", "state": "started", "tool": toolCall.name, "call_id": toolCall.callID],
                config: config
            )
            let execution = try timed {
                try executeToolCall(toolCall, config: config)
            }
            let toolResultPayload = [
                "result": execution.value.replayOutput,
                "status_code": String(execution.value.toolResult.status_code),
                "runtime_duration_ms": String(execution.value.toolResult.runtime_duration_ms),
                "call_id": toolCall.callID,
                "truncated": String(execution.value.toolResult.truncated),
                "total_bytes": String(execution.value.toolResult.total_bytes),
                "artifact_path": execution.value.toolResult.artifact_path ?? ""
            ]
            try logEvent(
                type: "step",
                payload: [
                    "name": "tool_execution",
                    "state": "finished",
                    "tool": toolCall.name,
                    "call_id": toolCall.callID,
                    "duration_ms": String(execution.durationMs)
                ],
                config: config
            )
            config.conversationState.appendFunctionCallOutput(callID: toolCall.callID, output: execution.value.replayOutput)
            try logEvent(
                type: "tool_result",
                payload: toolResultPayload,
                config: config
            )
        }
    }
}

func callModelWithTools(
    replayInputItems: [ResponseInputItem],
    promptConfig: PromptConfig,
    modelBackend: WispModelBackend,
    sessionID: String
) throws -> (assistantMessages: [String], toolCalls: [ToolCall]) {
    let url = try modelBackend.responsesURL()
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let instructions = promptConfig.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let promptCacheKey = buildPromptCacheKey(sessionID: sessionID)
    let headers = try buildModelRequestHeaders(for: modelBackend, sessionID: promptCacheKey)
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }

    var payload: [String: Any] = [
        "model": modelBackend.model,
        "instructions": instructions,
        "prompt_cache_key": promptCacheKey,
        "store": false,
        "stream": true,
        "input": try jsonObject(replayInputItems),
        "tools": makeToolDefinitions()
    ]
    if let reasoningEffort = modelBackend.reasoningEffort {
        payload["reasoning"] = ["effort": reasoningEffort, "summary": "auto"]
    }
    if modelBackend.sendsCodexOnlyRequestFields {
        payload["tool_choice"] = "auto"
        payload["parallel_tool_calls"] = true
    } else {
        payload.removeValue(forKey: "prompt_cache_key")
        payload.removeValue(forKey: "store")
    }

    let requestBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    request.httpBody = requestBody
    return try streamToolCallingResponse(request)
}

func buildModelRequestHeaders(for backend: WispModelBackend, sessionID: String) throws -> [String: String] {
    if backend.usesCodexOAuth {
        guard let authFile = backend.authFile else {
            throw AppError.io("Codex provider requires an auth file.")
        }
        let token = try loadCodexOAuthToken(authFile: authFile)
        return try CodexOAuth.buildSSEHeaders(token: token, sessionID: sessionID)
    }

    var headers = [
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
        "User-Agent": "wisp",
        "x-client-request-id": sessionID
    ]
    if let envName = backend.apiKeyEnvironmentVariable,
       let apiKey = ProcessInfo.processInfo.environment[envName]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !apiKey.isEmpty {
        headers["Authorization"] = "Bearer \(apiKey)"
    }
    return headers
}

func makeToolDefinitions() -> [[String: Any]] {
    [
        [
            "type": "function",
            "name": "read",
            "description": "Read a file.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "offset": ["type": "number"],
                    "limit": ["type": "number"]
                ],
                "required": ["path"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "bash",
            "description": "Run a shell command for inspection/search.",
            "parameters": [
                "type": "object",
                "properties": [
                    "command": ["type": "string"],
                    "timeout": ["type": "number"]
                ],
                "required": ["command"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "note",
            "description": "Create a new markdown note with the standard prelude.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "summary": ["type": "string"],
                    "content": ["type": "string"],
                    "artifacts": ["type": "array", "items": ["type": "string"]],
                    "path": ["type": "string"]
                ],
                "required": ["title", "summary"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "task",
            "description": "Create a new task note with the standard prelude and task fields.",
            "parameters": [
                "type": "object",
                "properties": [
                    "title": ["type": "string"],
                    "summary": ["type": "string"],
                    "content": ["type": "string"],
                    "artifacts": ["type": "array", "items": ["type": "string"]],
                    "due": ["type": "string"],
                    "time": ["type": "string"],
                    "place": ["type": "string"],
                    "status": ["type": "string"],
                    "path": ["type": "string"]
                ],
                "required": ["title", "summary"],
                "additionalProperties": false
            ]
        ],
        [
            "type": "function",
            "name": "edit",
            "description": "Apply exact text replacements; each oldText must match once.",
            "parameters": [
                "type": "object",
                "properties": [
                    "path": ["type": "string"],
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "oldText": ["type": "string"],
                                "newText": ["type": "string"]
                            ],
                            "required": ["oldText", "newText"],
                            "additionalProperties": false
                        ]
                    ]
                ],
                "required": ["path", "edits"],
                "additionalProperties": false
            ]
        ]
    ]
}

private func decodeStreamEvent(_ payload: String) -> [String: Any]? {
    guard let eventData = payload.data(using: .utf8),
          let eventJSON = try? JSONSerialization.jsonObject(with: eventData, options: []),
          let event = eventJSON as? [String: Any],
          event["type"] as? String != nil else {
        return nil
    }
    return event
}

private func extractStreamFailureMessage(from event: [String: Any], eventType: String) -> String {
    if let errorObj = event["error"] as? [String: Any],
       let message = nonEmptyText(errorObj["message"]) {
        return message
    }
    if let message = nonEmptyText(event["message"]) {
        return message
    }
    return "Responses stream failed with event type \(eventType)"
}

private final class ToolCallingStreamParser {
    private var currentDataLines: [String] = []
    private var streamFailureMessage: String?
    private var lastUnparsedEventPreview: String?
    private var streamPreviewParts: [String] = []
    private var assistantMessages: [String] = []
    private var toolCalls: [ToolCall] = []
    private var streamedAssistantText = ""

    func consume(line rawLine: String) throws -> (assistantMessages: [String], toolCalls: [ToolCall])? {
        if streamPreviewParts.count < 40 {
            streamPreviewParts.append(rawLine)
        }
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            return try flushEvent()
        }
        if line.hasPrefix("data:") {
            let dataLine = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if !currentDataLines.isEmpty {
                if let result = try flushEvent() {
                    return result
                }
            }
            currentDataLines.append(dataLine)
        }
        return nil
    }

    func finish() throws -> (assistantMessages: [String], toolCalls: [ToolCall]) {
        if let result = try flushEvent() {
            return result
        }
        flushStreamedAssistantText()
        if !assistantMessages.isEmpty || !toolCalls.isEmpty {
            return (assistantMessages, toolCalls)
        }
        if let streamFailureMessage, !streamFailureMessage.isEmpty {
            throw AppError.invalidModelResponse("Responses stream failed: \(streamFailureMessage)")
        }
        var details: [String] = []
        if let lastUnparsedEventPreview, !lastUnparsedEventPreview.isEmpty {
            details.append("unparsed event preview: \(lastUnparsedEventPreview)")
        }
        let preview = compactText(streamPreviewParts.joined(separator: "\n"), limit: 1_200)
        if !preview.isEmpty {
            details.append("stream preview: \(preview)")
        }
        throw AppError.invalidModelResponse("Could not decode tool-calling response. \(details.joined(separator: " | "))")
    }

    private func flushEvent() throws -> (assistantMessages: [String], toolCalls: [ToolCall])? {
        guard !currentDataLines.isEmpty else { return nil }
        let payload = currentDataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        currentDataLines.removeAll(keepingCapacity: true)
        guard !payload.isEmpty, payload != "[DONE]" else { return nil }
        guard let event = decodeStreamEvent(payload),
              let eventType = event["type"] as? String else {
            lastUnparsedEventPreview = compactText(payload, limit: 1_200)
            return nil
        }

        switch eventType {
        case "response.output_text.delta":
            if let delta = event["delta"] as? String {
                streamedAssistantText += delta
            }
        case "response.output_text.done":
            if let text = nonEmptyText(event["text"]) {
                streamedAssistantText = text
                flushStreamedAssistantText()
            }
        case "response.output_item.done":
            if let item = event["item"] as? [String: Any] {
                consumeOutputItem(item)
            }
        case "response.completed":
            flushStreamedAssistantText()
            if let response = event["response"] as? [String: Any],
               let output = response["output"] as? [[String: Any]],
               !output.isEmpty {
                let extracted = extractToolCallingResponse(from: response)
                merge(assistantMessages: extracted.assistantMessages, toolCalls: extracted.toolCalls)
            }
            if !assistantMessages.isEmpty || !toolCalls.isEmpty {
                return (assistantMessages, toolCalls)
            }
        case "response.failed", "error":
            streamFailureMessage = extractStreamFailureMessage(from: event, eventType: eventType)
        default:
            break
        }
        return nil
    }

    private func consumeOutputItem(_ item: [String: Any]) {
        if let text = extractAssistantMessage(from: item) {
            appendAssistantMessage(text)
            return
        }
        guard let toolCall = extractToolCall(from: item) else { return }
        if !toolCalls.contains(where: { $0.callID == toolCall.callID }) {
            toolCalls.append(toolCall)
        }
    }

    private func flushStreamedAssistantText() {
        let text = streamedAssistantText.trimmingCharacters(in: .whitespacesAndNewlines)
        streamedAssistantText = ""
        appendAssistantMessage(text)
    }

    private func appendAssistantMessage(_ text: String) {
        guard !text.isEmpty else { return }
        if assistantMessages.last == text { return }
        assistantMessages.append(text)
    }

    private func merge(assistantMessages newMessages: [String], toolCalls newToolCalls: [ToolCall]) {
        for message in newMessages {
            appendAssistantMessage(message)
        }
        for toolCall in newToolCalls where !toolCalls.contains(where: { $0.callID == toolCall.callID }) {
            toolCalls.append(toolCall)
        }
    }
}

func streamToolCallingResponse(_ request: URLRequest) throws -> (assistantMessages: [String], toolCalls: [ToolCall]) {
    let semaphore = DispatchSemaphore(value: 0)
    final class StreamState: @unchecked Sendable {
        var result: (assistantMessages: [String], toolCalls: [ToolCall])?
        var error: Error?
    }
    let state = StreamState()

    Task {
        defer { semaphore.signal() }
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.requestFailed("No HTTP status code from API")
            }
            guard (200..<300).contains(http.statusCode) else {
                var body = ""
                for try await line in bytes.lines {
                    if body.count >= 4_000 { break }
                    body += line + "\n"
                }
                throw AppError.requestFailed("HTTP \(http.statusCode): \(body.trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            let parser = ToolCallingStreamParser()
            for try await line in bytes.lines {
                if let result = try parser.consume(line: line) {
                    state.result = result
                    return
                }
            }

            state.result = try parser.finish()
        } catch {
            state.error = error
        }
    }

    semaphore.wait()
    if let error = state.error {
        throw error
    }
    guard let result = state.result else {
        throw AppError.invalidModelResponse("Tool-calling response ended without a result")
    }
    return result
}

private func extractAssistantMessage(from item: [String: Any]) -> String? {
    guard (item["type"] as? String) == "message",
          let content = item["content"] as? [[String: Any]] else {
        return nil
    }
    let parts = content.compactMap { part -> String? in
        switch part["type"] as? String {
        case "output_text":
            return nonEmptyText(part["text"])
        case "refusal":
            return nonEmptyText(part["refusal"])
        default:
            return nil
        }
    }
    let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}

private func extractToolCall(from item: [String: Any]) -> ToolCall? {
    guard (item["type"] as? String) == "function_call" else {
        return nil
    }
    let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let arguments = (item["arguments"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "{}"
    guard !callID.isEmpty, !name.isEmpty else {
        return nil
    }
    return ToolCall(callID: callID, name: name, arguments: arguments)
}

func extractToolCallingResponse(from responseObject: [String: Any]) -> (assistantMessages: [String], toolCalls: [ToolCall]) {
    let output = responseObject["output"] as? [[String: Any]] ?? []
    var assistantMessages: [String] = []
    var toolCalls: [ToolCall] = []

    for item in output {
        if let text = extractAssistantMessage(from: item) {
            assistantMessages.append(text)
            continue
        }
        if let toolCall = extractToolCall(from: item) {
            toolCalls.append(toolCall)
        }
    }

    return (assistantMessages, toolCalls)
}

func executeToolCall(_ toolCall: ToolCall, config: CLIConfig) throws -> (toolResult: ToolResult, replayOutput: String) {
    let directOutput: ToolExecutionOutput
    switch toolCall.name {
    case "read":
        let args = try decodeToolArguments(ReadToolArguments.self, from: toolCall.arguments, toolName: toolCall.name)
        directOutput = try executeReadTool(path: args.path, offset: args.offset, limit: args.limit, config: config)
    case "bash":
        let args = try decodeToolArguments(BashToolArguments.self, from: toolCall.arguments, toolName: toolCall.name)
        directOutput = try executeBashTool(command: args.command, timeoutSeconds: args.timeout, config: config)
    case "note":
        let args = try decodeToolArguments(NoteToolArguments.self, from: toolCall.arguments, toolName: toolCall.name)
        directOutput = try executeNoteTool(args: args, config: config)
    case "task":
        let args = try decodeToolArguments(TaskToolArguments.self, from: toolCall.arguments, toolName: toolCall.name)
        directOutput = try executeTaskTool(args: args, config: config)
    case "edit":
        let args = try decodeToolArguments(EditToolArguments.self, from: toolCall.arguments, toolName: toolCall.name)
        directOutput = try executeEditTool(path: args.path, edits: args.edits, config: config)
    default:
        directOutput = ToolExecutionOutput(
            status_code: 1,
            stdout: "",
            stderr: "Unknown tool: \(toolCall.name)",
            truncation_mode: "head",
            runtime_duration_ms: 0
        )
    }

    let modelToolResult = try buildToolResult(from: directOutput, logPath: config.logPath)
    return (modelToolResult, try encodeReplayToolResult(modelToolResult))
}

func decodeToolArguments<T: Decodable>(_ type: T.Type, from json: String, toolName: String) throws -> T {
    guard let data = json.data(using: .utf8) else {
        throw AppError.invalidModelResponse("Tool arguments for \(toolName) were not utf8")
    }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        throw AppError.invalidModelResponse("Could not decode arguments for \(toolName): \(json)")
    }
}

func executeReadTool(path: String, offset: Int?, limit: Int?, config: CLIConfig) throws -> ToolExecutionOutput {
    let startedAt = Date()
    let resolved = try resolveReadablePath(path: path, config: config)
    let text = try loadUTF8File(at: resolved)
    let startLine = max(0, (offset ?? 1) - 1)
    var selectedLines = text.components(separatedBy: .newlines)
    if startLine >= selectedLines.count {
        return ToolExecutionOutput(
            status_code: 1,
            stdout: "",
            stderr: "read: offset \(offset ?? 1) is beyond end of file (\(selectedLines.count) lines total)",
            truncation_mode: "head",
            runtime_duration_ms: wallDurationMs(since: startedAt)
        )
    }
    let endLineExclusive = limit != nil ? min(selectedLines.count, startLine + max(0, limit ?? 0)) : min(selectedLines.count, startLine + readOrBashMaxLines)
    selectedLines = Array(selectedLines[startLine..<endLineExclusive])
    let stdout = selectedLines.joined(separator: "\n")
    return ToolExecutionOutput(
        status_code: 0,
        stdout: stdout,
        stderr: "",
        truncation_mode: "head",
        runtime_duration_ms: wallDurationMs(since: startedAt)
    )
}

func executeBashTool(command: String, timeoutSeconds: Int?, config: CLIConfig) throws -> ToolExecutionOutput {
    let startedAt = Date()
    let timeoutMs = max(1, (timeoutSeconds ?? 15) * 1000)
    let result = try runBashCommand(command: command, timeoutMs: timeoutMs, currentDirectory: config.workingDirectory)
    return ToolExecutionOutput(
        status_code: result.statusCode,
        stdout: result.stdout,
        stderr: result.stderr,
        truncation_mode: "tail",
        runtime_duration_ms: wallDurationMs(since: startedAt)
    )
}

private func executeCreationTool(startedAt: Date, create: () throws -> String) -> ToolExecutionOutput {
    do {
        let path = try create()
        return ToolExecutionOutput(
            status_code: 0,
            stdout: "created \(path)",
            stderr: "",
            truncation_mode: "head",
            runtime_duration_ms: wallDurationMs(since: startedAt)
        )
    } catch {
        return ToolExecutionOutput(
            status_code: 1,
            stdout: "",
            stderr: String(describing: error),
            truncation_mode: "head",
            runtime_duration_ms: wallDurationMs(since: startedAt)
        )
    }
}

private func executeNoteTool(args: NoteToolArguments, config: CLIConfig) throws -> ToolExecutionOutput {
    let startedAt = Date()
    return executeCreationTool(startedAt: startedAt) {
        try createNoteFile(
            title: args.title,
            summary: args.summary,
            content: args.content ?? "",
            artifacts: args.artifacts ?? [],
            explicitPath: args.path,
            config: config
        )
    }
}

private func executeTaskTool(args: TaskToolArguments, config: CLIConfig) throws -> ToolExecutionOutput {
    let startedAt = Date()
    return executeCreationTool(startedAt: startedAt) {
        try createTaskFile(
            title: args.title,
            summary: args.summary,
            content: args.content ?? "",
            artifacts: args.artifacts ?? [],
            due: args.due,
            time: args.time,
            place: args.place,
            status: args.status,
            explicitPath: args.path,
            config: config
        )
    }
}

private func executeEditTool(path: String, edits: [EditToolArguments.EditReplacement], config: CLIConfig) throws -> ToolExecutionOutput {
    let startedAt = Date()
    do {
        guard !edits.isEmpty else {
            throw AppError.io("edit: edits must be non-empty")
        }
        let target = try resolveWritableWikiPath(rawPath: path, wikiRoot: config.wikiRoot)
        let original = try loadUTF8File(at: target)
        let updated = touchModifiedLineIfPresent(try applyExactEdits(original: original, edits: edits))
        try updated.write(to: target, atomically: true, encoding: .utf8)
        let diff = buildUnifiedDiff(path: target.path, oldContent: original, newContent: updated)
        return ToolExecutionOutput(
            status_code: 0,
            stdout: diff,
            stderr: "",
            truncation_mode: "head",
            runtime_duration_ms: wallDurationMs(since: startedAt)
        )
    } catch {
        return ToolExecutionOutput(
            status_code: 1,
            stdout: "",
            stderr: String(describing: error),
            truncation_mode: "head",
            runtime_duration_ms: wallDurationMs(since: startedAt)
        )
    }
}

func wallDurationMs(since startedAt: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(startedAt) * 1000.0))
}

func resolveReadablePath(path: String, config: CLIConfig) throws -> URL {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw AppError.io("read: path must be non-empty")
    }
    let resolved: URL
    if trimmed.hasPrefix("/") {
        resolved = URL(fileURLWithPath: trimmed).standardizedFileURL
        guard isPathWithinRoot(resolved, root: config.repoRoot) || isPathWithinRoot(resolved, root: config.wikiRoot) else {
            throw AppError.io("read: absolute path must be inside repo root or wiki root")
        }
    } else {
        resolved = config.wikiRoot.appendingPathComponent(trimmed).standardizedFileURL
        guard isPathWithinRoot(resolved, root: config.wikiRoot) else {
            throw AppError.io("read: refusing to read outside wiki root")
        }
    }
    return resolved
}

func isPathWithinRoot(_ path: URL, root: URL) -> Bool {
    let rootPath = root.standardizedFileURL.path
    let resolvedPath = path.standardizedFileURL.path
    return resolvedPath == rootPath || resolvedPath.hasPrefix(rootPath + "/")
}

func loadUTF8File(at url: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw AppError.io("Missing file at \(url.path)")
    }
    guard let data = FileManager.default.contents(atPath: url.path),
          let text = String(data: data, encoding: .utf8) else {
        throw AppError.io("Could not read utf8 file at \(url.path)")
    }
    return text
}

private func applyExactEdits(original: String, edits: [EditToolArguments.EditReplacement]) throws -> String {
    struct MatchedEdit {
        let start: String.Index
        let end: String.Index
        let replacement: String
    }

    var matches: [MatchedEdit] = []
    for edit in edits {
        guard !edit.oldText.isEmpty else {
            throw AppError.io("edit: oldText must be non-empty")
        }
        guard let firstRange = original.range(of: edit.oldText) else {
            throw AppError.io("edit: oldText not found")
        }
        let searchStart = firstRange.upperBound
        if original.range(of: edit.oldText, range: searchStart..<original.endIndex) != nil {
            throw AppError.io("edit: oldText matched multiple locations; make it more specific")
        }
        matches.append(MatchedEdit(start: firstRange.lowerBound, end: firstRange.upperBound, replacement: edit.newText))
    }

    let sorted = matches.sorted { $0.start < $1.start }
    for idx in 1..<sorted.count {
        if sorted[idx - 1].end > sorted[idx].start {
            throw AppError.io("edit: oldText matches overlap")
        }
    }

    var result = ""
    var cursor = original.startIndex
    for match in sorted {
        result += original[cursor..<match.start]
        result += match.replacement
        cursor = match.end
    }
    result += original[cursor..<original.endIndex]
    return result
}

func buildUnifiedDiff(path: String, oldContent: String, newContent: String) -> String {
    let oldLines = oldContent.components(separatedBy: .newlines)
    let newLines = newContent.components(separatedBy: .newlines)

    var prefix = 0
    while prefix < oldLines.count && prefix < newLines.count && oldLines[prefix] == newLines[prefix] {
        prefix += 1
    }

    var suffix = 0
    while suffix < (oldLines.count - prefix) && suffix < (newLines.count - prefix) && oldLines[oldLines.count - suffix - 1] == newLines[newLines.count - suffix - 1] {
        suffix += 1
    }

    let oldStart = prefix + 1
    let newStart = prefix + 1
    let oldEnd = oldLines.count - suffix
    let newEnd = newLines.count - suffix
    let oldSpan = max(0, oldEnd - oldStart + 1)
    let newSpan = max(0, newEnd - newStart + 1)

    var lines: [String] = [
        "--- \(path)",
        "+++ \(path)",
        "@@ -\(oldStart),\(oldSpan) +\(newStart),\(newSpan) @@"
    ]
    if oldSpan == 0 && newSpan == 0 {
        lines.append("(no textual changes)")
        return lines.joined(separator: "\n")
    }
    if oldSpan > 0 {
        for idx in (oldStart - 1)..<min(oldLines.count, oldEnd) {
            lines.append("-\(oldLines[idx])")
        }
    }
    if newSpan > 0 {
        for idx in (newStart - 1)..<min(newLines.count, newEnd) {
            lines.append("+\(newLines[idx])")
        }
    }
    return lines.joined(separator: "\n")
}
