import AppIntents

struct FastCaptureIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk with Wisp"
    static let description = IntentDescription("Open Wisp directly to a quick voice or text capture screen.")
    static let openAppWhenRun = true

    @Parameter(
        title: "Text",
        inputConnectionBehavior: .connectToPreviousIntentResult
    )
    var text: String?

    func perform() async throws -> some IntentResult {
        let prefilledText = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        await WispAppRouter.shared.openFastCapture(prefilledText: prefilledText)
        return .result()
    }
}

struct WispAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: FastCaptureIntent(),
            phrases: [
                "Talk with \(.applicationName)",
                "Ask \(.applicationName)",
                "New Wisp note with \(.applicationName)"
            ],
            shortTitle: "Talk",
            systemImageName: "mic.badge.plus"
        )
    }
}
