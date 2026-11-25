import Foundation
import UserNotifications
#if canImport(AlarmKit)
import AlarmKit
import SwiftUI
import CryptoKit
#endif

enum Notice {
    static let personal = "solo.personal."
    static let receiver = "solo.receiver."
    static let category = "solo.check-in"
    static let checkAction = "solo.i-am-okay"
    static let refresh = "solo.refresh."
    static let test = "solo.test."
    static let recovered = "solo.recovered."
    static let capacity = 52
    static let auxiliaryCapacity = 56

    static func prefix(_ pair: UUID) -> String { receiver + pair.uuidString + "." }
    static func id(_ pair: UUID, _ window: Window) -> String { prefix(pair) + window.id }
    static func horizon(at now: Date) -> Date { now.addingTimeInterval(7 * 86_400) }
}

@MainActor
final class Notifications {
    private let center = UNUserNotificationCenter.current()
    private(set) var capability = "notice.disabled"

    struct Coverage {
        var until: Date?
        var count: Int
        var complete: Bool
    }

    func register() {
        guard !Launch.testing else { return }
        let action = UNNotificationAction(identifier: Notice.checkAction, title: L.t("home.check"), options: .authenticationRequired)
        center.setNotificationCategories([UNNotificationCategory(identifier: Notice.category, actions: [action],
                                                                  intentIdentifiers: [], options: [])])
    }

    func allow() async {
        guard !Launch.testing else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .timeSensitive])
    }

    func allowed() async -> Bool {
        if Launch.testing { return true }
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
    }

    func personal(_ state: CheckInState, now: Date) async {
        guard !Launch.testing else { capability = "notice.sensitive"; return }
        guard !state.clockWarning else { return }
        let settings = await center.notificationSettings()
        let canNotify = settings.authorizationStatus == .authorized && settings.alertSetting == .enabled
        let eligible = state.enabled ? state.plan.windows(around: now).filter {
            $0.deadline > now && $0.deadline <= Notice.horizon(at: now) && !state.hasChecked($0, at: now)
        } : []
        let windows = Array(eligible.prefix(8))
        let active = state.enabled ? state.plan.windows(around: now).filter {
            $0.deadline <= now && now <= $0.expiry && !state.hasChecked($0, at: now)
        } : []
        let alarms = await StrongAlarm.reconcile(windows: active + windows, enabled: state.alarmWanted)
        let previous = await center.pendingNotificationRequests()
        let outstanding = Set(previous.map(\.identifier).filter { $0.hasPrefix(Notice.personal) })
        let desired = Set(canNotify ? windows.filter { !alarms.contains($0.id) }.map { Notice.personal + $0.id } : [])
        center.removePendingNotificationRequests(withIdentifiers: Array(outstanding.subtracting(desired)))
        for window in windows where desired.contains(Notice.personal + window.id) && !outstanding.contains(Notice.personal + window.id) {
            let body = L.f("notice.grace", Int(window.expiry.timeIntervalSince(window.deadline) / 60))
            try? await add(id: Notice.personal + window.id, date: window.deadline, title: "notice.due",
                           body: body, category: Notice.category, window: window.id, sensitive: true)
        }
        center.removeDeliveredNotifications(withIdentifiers: state.checks.keys.map { Notice.personal + $0 })
        let pending = await center.pendingNotificationRequests()
        if let first = windows.first {
            if alarms.contains(first.id) { capability = "notice.alarm" }
            else if pending.contains(where: { $0.identifier == Notice.personal + first.id }) {
                capability = settings.timeSensitiveSetting == .enabled ? "notice.sensitive" : "notice.normal"
            } else { capability = "notice.unavailable" }
        } else {
            capability = canNotify ? (settings.timeSensitiveSetting == .enabled ? "notice.sensitive" : "notice.normal") : "notice.disabled"
        }
    }

    struct Candidate {
        let pair: UUID
        let window: Window
        var id: String { Notice.id(pair, window) }
    }

    func candidates(_ incoming: Incoming, plan: PlanChange?, now: Date) -> [Candidate] {
        guard let plan else { return [] }
        return plan.windows(around: now).filter {
            $0.expiry > now && $0.expiry <= Notice.horizon(at: now) && incoming.entries[$0.id] == nil
        }.map { Candidate(pair: incoming.id, window: $0) }
    }

    func stage(_ candidates: [Candidate], keeping protected: Set<String> = []) async -> Set<String> {
        let pending = await center.pendingNotificationRequests()
        var ids = Set(pending.map(\.identifier))
        let room = max(0, Notice.capacity - ids.count)
        let sorted = candidates.sorted {
            ($0.window.expiry, $0.id) < ($1.window.expiry, $1.id)
        }
        for candidate in sorted.filter({ !ids.contains($0.id) }).prefix(room) {
            do {
                try await add(id: candidate.id, date: candidate.window.expiry, title: "notice.review",
                              body: L.t("notice.reviewBody"), pair: candidate.pair, window: candidate.window.id)
                ids.insert(candidate.id)
            } catch { continue }
        }
        let verified = Set(await center.pendingNotificationRequests().map(\.identifier))
        return verified.intersection(Set(candidates.map(\.id)).union(protected))
    }

    func prune(_ pair: UUID, keep: Set<String>, entries: [String: CloudCheckIn], now: Date) async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let prefix = Notice.prefix(pair)
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
            $0.hasPrefix(prefix) && !keep.contains($0)
        })
        let resolved = delivered.filter { item in
            let id = item.request.identifier
            return id.hasPrefix(prefix) && entries[String(id.dropFirst(prefix.count))] != nil
        }
        for item in resolved {
            let id = String(item.request.identifier.dropFirst(prefix.count))
            let recoveryID = Notice.recovered + pair.uuidString + "." + id
            if let entry = entries[id], entry.uploaded > entry.entry.window.expiry,
               now.timeIntervalSince(item.date) < 86_400,
               !delivered.contains(where: { $0.request.identifier == recoveryID }),
               !pending.contains(where: { $0.identifier == recoveryID }),
               await allowed() {
                try? await auxiliary(id: recoveryID, date: Date().addingTimeInterval(2), title: "notice.updated",
                                     body: "notice.updatedBody", pair: pair, window: id)
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: resolved.map { $0.request.identifier })
    }

    func coverage(_ candidates: [Candidate], ids: Set<String>, now: Date) -> Coverage {
        let ordered = candidates.sorted { $0.window.expiry < $1.window.expiry }
        guard let firstMissing = ordered.firstIndex(where: { !ids.contains($0.id) }) else {
            return Coverage(until: Notice.horizon(at: now), count: ordered.count, complete: true)
        }
        let until = ordered[firstMissing].window.expiry.addingTimeInterval(-1)
        return Coverage(until: until, count: firstMissing, complete: false)
    }

    func promptRenewal(_ pair: UUID, coverage: Coverage, now: Date) async {
        let id = Notice.refresh + pair.uuidString
        guard let until = coverage.until, until > now.addingTimeInterval(3600) else { return }
        let date = max(until.addingTimeInterval(-24 * 3600), now.addingTimeInterval(3600))
        if let old = await center.pendingNotificationRequests().first(where: { $0.identifier == id }),
           let trigger = old.trigger as? UNCalendarNotificationTrigger, let time = trigger.nextTriggerDate(),
           abs(time.timeIntervalSince(date)) < 3600 { return }
        try? await auxiliary(id: id, date: date, title: "notice.renew", body: "notice.renewBody", pair: pair)
    }

    func sendTest(_ pair: UUID, event: UUID) async throws {
        guard await allowed() else { throw LocalError.permission }
        if Launch.testing { return }
        try await auxiliary(id: Notice.test + pair.uuidString + "." + event.uuidString,
                            date: Date().addingTimeInterval(2), title: "notice.test", body: "notice.testBody", pair: pair)
    }

    func remove(_ pair: UUID) async {
        guard !Launch.testing else { return }
        let prefixes = [Notice.prefix(pair), Notice.refresh + pair.uuidString, Notice.test + pair.uuidString, Notice.recovered + pair.uuidString]
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { id in prefixes.contains { id.hasPrefix($0) } })
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { id in prefixes.contains { id.hasPrefix($0) } })
    }

    func clear() async {
        guard !Launch.testing else { return }
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        _ = await StrongAlarm.reconcile(windows: [], enabled: false)
    }

    private func auxiliary(id: String, date: Date, title: String, body: String, pair: UUID, window: String? = nil) async throws {
        let pending = await center.pendingNotificationRequests()
        guard pending.count < Notice.auxiliaryCapacity || pending.contains(where: { $0.identifier == id }) else {
            throw LocalError.busy
        }
        try await add(id: id, date: date, title: title, body: L.t(body), pair: pair, window: window)
    }

    private func add(id: String, date: Date, title: String, body: String, category: String = "",
                     pair: UUID? = nil, window: String? = nil, sensitive: Bool = false) async throws {
        guard date > Date() else { throw LocalError.stale }
        let content = UNMutableNotificationContent()
        content.title = L.t(title)
        content.body = body
        content.sound = .default
        content.interruptionLevel = sensitive ? .timeSensitive : .active
        content.categoryIdentifier = category
        if let pair { content.userInfo["pair"] = pair.uuidString }
        if let window { content.userInfo["window"] = window }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

@MainActor
enum StrongAlarm {
    static var supported: Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26, *) { return true }
        #endif
        return false
    }

    static func authorize() async -> Bool {
        #if canImport(AlarmKit)
        if #available(iOS 26, *) { return (try? await AlarmManager.shared.requestAuthorization()) == .authorized }
        #endif
        return false
    }

    static func reconcile(windows: [Window], enabled: Bool) async -> Set<String> {
        #if canImport(AlarmKit)
        if #available(iOS 26, *) { return await alarms(windows, enabled: enabled) }
        #endif
        return []
    }

    #if canImport(AlarmKit)
    @available(iOS 26, *)
    private struct Reminder: AlarmMetadata {}

    @available(iOS 26, *)
    private static func alarms(_ windows: [Window], enabled: Bool) async -> Set<String> {
        let manager = AlarmManager.shared
        guard manager.authorizationState == .authorized else { return [] }
        let desired = enabled ? windows : []
        let ids = Set(desired.map { key($0.id) })
        let scheduled = (try? manager.alarms) ?? []
        for alarm in scheduled where !ids.contains(alarm.id) {
            do { try manager.cancel(id: alarm.id) } catch { try? manager.stop(id: alarm.id) }
        }
        var result = Set<String>()
        for window in desired {
            let id = key(window.id)
            if scheduled.contains(where: { $0.id == id }) { result.insert(window.id); continue }
            guard window.deadline > Date() else { continue }
            let title = L.f("notice.alarmTitle", Int(window.expiry.timeIntervalSince(window.deadline) / 60))
            let button = AlarmButton(text: "notice.stop", textColor: .white, systemImageName: "stop.circle")
            let presentation = AlarmPresentation(alert: .init(title: LocalizedStringResource(stringLiteral: title), stopButton: button))
            let attributes = AlarmAttributes(presentation: presentation, metadata: Reminder(), tintColor: .blue)
            do {
                _ = try await manager.schedule(id: id, configuration: .alarm(schedule: .fixed(window.deadline), attributes: attributes))
                result.insert(window.id)
            } catch { continue }
        }
        return result
    }

    private static func key(_ text: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
    #endif
}
