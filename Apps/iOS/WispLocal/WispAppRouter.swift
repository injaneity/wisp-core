import Foundation

struct WispFastCaptureRequest: Identifiable, Equatable {
    let id = UUID()
    var prefilledText: String
}

@MainActor
final class WispAppRouter: ObservableObject {
    static let shared = WispAppRouter()

    @Published var fastCaptureRequest: WispFastCaptureRequest?

    private init() {}

    func openFastCapture(prefilledText: String = "") {
        fastCaptureRequest = WispFastCaptureRequest(prefilledText: prefilledText)
    }
}
