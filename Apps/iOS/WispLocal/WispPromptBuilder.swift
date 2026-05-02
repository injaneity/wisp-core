import Foundation

enum WispPromptBuilder {
    static func chatTranscript(messages: [ChatMessage]) -> String {
        var lines = [
            "System: You are Wisp, a concise personal assistant running inside an iPhone app."
        ]
        for message in messages {
            lines.append("\(message.role.promptLabel): \(message.text)")
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    static func fastCapture(text: String) -> String {
        [
            "System: You are Wisp, a concise personal assistant running inside an iPhone app.",
            "The user opened Fast Capture from a shortcut or the Action Button.",
            "Respond directly and briefly. If the capture sounds like a note, reminder, draft, or task, structure it into useful next steps.",
            "User: \(text)",
            "Assistant:"
        ].joined(separator: "\n\n")
    }
}
