import AppIntents
import Foundation

struct CheckInIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "home.check"
    static var description = IntentDescription("widget.description")
    static var openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    func perform() async throws -> some IntentResult {
        #if WIDGET_EXTENSION
        #else
        guard await AppModel.shared.check() else { return .result() }
        await AppModel.shared.refresh()
        #endif
        return .result()
    }
}
