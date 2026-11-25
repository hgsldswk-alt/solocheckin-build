import Foundation

enum Launch {
    static let freePeriod = false
    static let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
    static let testing = arguments.contains("-ui-testing")
    #else
    static let testing = false
    #endif
    static var isFree: Bool {
        freePeriod && !(testing && arguments.contains { ["-paid-mode", "-expired", "-paywall"].contains($0) })
    }
    static func value(_ flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
