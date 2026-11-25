import Foundation

private final class TranslationBundle: NSObject {}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: Bundle(for: TranslationBundle.self), comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }

    static func clock(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    static func stamp(_ date: Date, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = zone
        return formatter.string(from: date)
    }

    static func zone(_ zone: TimeZone, at date: Date) -> String {
        zone.localizedName(for: zone.isDaylightSavingTime(for: date) ? .daylightSaving : .standard,
                           locale: .current) ?? zone.identifier
    }
}
