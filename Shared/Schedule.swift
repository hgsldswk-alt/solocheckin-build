import Foundation

struct DailyRule: Codable, Equatable {
    static let graceOptions = [15, 30, 60, 120]
    var hour = 21
    var minute = 0
    var grace = 30
    var zoneID = TimeZone.current.identifier

    var zone: TimeZone { TimeZone(identifier: zoneID) ?? TimeZone(secondsFromGMT: 0)! }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }
    var valid: Bool {
        (0..<24).contains(hour) && (0..<60).contains(minute)
            && Self.graceOptions.contains(grace) && TimeZone(identifier: zoneID) != nil
    }

    func deadline(on day: Date) -> Date? {
        let start = calendar.startOfDay(for: day)
        guard let deadline = calendar.nextDate(after: start.addingTimeInterval(-1),
                                               matching: DateComponents(hour: hour, minute: minute, second: 0),
                                               matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                               direction: .forward),
              calendar.isDate(deadline, inSameDayAs: day) else { return nil }
        return deadline
    }

    func followingDay(after date: Date) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }
}

struct Trip: Codable, Equatable, Identifiable {
    var id = UUID()
    var starts: Date
    var returns: Date
    var grace: Int
    var expiry: Date { returns.addingTimeInterval(Double(grace) * 60) }
    var valid: Bool {
        starts.timeIntervalSinceReferenceDate.isFinite && returns.timeIntervalSinceReferenceDate.isFinite
            && returns > starts && returns.timeIntervalSince(starts) <= 30 * 86_400
            && DailyRule.graceOptions.contains(grace)
    }
}

struct Window: Codable, Equatable, Identifiable {
    let id: String
    let version: Int
    let opens: Date
    let deadline: Date
    let expiry: Date
    let zoneID: String
    let isTrip: Bool

    enum Timing: Equatable { case early, grace, overdue }
    func timing(at date: Date) -> Timing {
        if date > expiry { return .overdue }
        return date < deadline ? .early : .grace
    }
}

struct Plan: Codable, Equatable {
    var version = 1
    var effective = Date.distantPast
    var rule = DailyRule()
    var pausedFrom: Date?
    var pausedUntil: Date?
    var trips: [Trip] = []

    var valid: Bool {
        version > 0 && version < Int.max && effective.timeIntervalSinceReferenceDate.isFinite
            && rule.valid && trips.count <= 12 && trips.allSatisfy(\.valid)
            && Set(trips.map(\.id)).count == trips.count
            && zip(orderedTrips, orderedTrips.dropFirst()).allSatisfy { $0.0.expiry <= $0.1.starts }
            && [pausedFrom, pausedUntil].compactMap { $0 }.allSatisfy { $0.timeIntervalSinceReferenceDate.isFinite }
            && ((pausedFrom == nil && pausedUntil == nil) || (pausedFrom ?? .distantFuture) < (pausedUntil ?? .distantPast))
    }

    private var orderedTrips: [Trip] { trips.sorted { $0.starts < $1.starts } }

    func windows(around now: Date, daysBefore: Int = 1, daysAfter: Int = 7) -> [Window] {
        guard valid else { return [] }
        let calendar = rule.calendar
        let day = calendar.startOfDay(for: now)
        var result = (-daysBefore...daysAfter).compactMap { offset -> Window? in
            guard let start = calendar.date(byAdding: .day, value: offset, to: day),
                  let deadline = rule.deadline(on: start), deadline >= effective else { return nil }
            let expiry = deadline.addingTimeInterval(Double(rule.grace) * 60)
            if let from = pausedFrom, let until = pausedUntil, deadline >= from, deadline < until { return nil }
            if trips.contains(where: { $0.starts <= expiry && deadline < $0.expiry }) { return nil }
            let tripEnd = trips.map(\.expiry).filter { $0 > start && $0 <= deadline }.max() ?? start
            let opens = max(start, effective, tripEnd)
            return Window(id: "v\(version)-day-\(Int(deadline.timeIntervalSince1970))", version: version,
                          opens: opens, deadline: deadline, expiry: expiry, zoneID: rule.zoneID, isTrip: false)
        }
        let earliest = calendar.date(byAdding: .day, value: -daysBefore, to: day) ?? day
        let latest = calendar.date(byAdding: .day, value: daysAfter + 1, to: day) ?? now
        result += trips.filter { $0.expiry >= earliest && $0.starts < latest && $0.returns >= effective }.map {
            Window(id: "v\(version)-trip-\($0.id.uuidString.lowercased())", version: version,
                   opens: max($0.starts, effective), deadline: $0.returns, expiry: $0.expiry,
                   zoneID: rule.zoneID, isTrip: true)
        }
        return result.sorted { $0.deadline < $1.deadline }
    }
}

struct PlanChange: Codable, Equatable {
    var current: Plan
    var next: Plan?

    func windows(around now: Date, before: Int = 1, after: Int = 7) -> [Window] {
        let previous = current.windows(around: now, daysBefore: before, daysAfter: after)
        guard let next else { return previous }
        return (previous.filter { $0.opens < next.effective && $0.deadline < next.effective }
                + next.windows(around: now, daysBefore: before, daysAfter: after))
            .sorted { $0.deadline < $1.deadline }
    }

    var valid: Bool {
        current.valid && (next.map { $0.valid && $0.version > current.version && $0.effective > current.effective } ?? true)
    }
}

enum Periods {
    static func target(in windows: [Window], at now: Date) -> Window? {
        let open = windows.filter { $0.opens <= now }.sorted { $0.deadline < $1.deadline }
        if let previous = open.dropLast().last, now <= previous.expiry {
            return previous
        }
        return open.last
    }

    static func receiverCovers(_ window: Window, clicked: Date, uploaded: Date) -> Bool {
        clicked >= window.opens && uploaded >= window.opens && clicked <= uploaded.addingTimeInterval(600) && uploaded <= window.expiry
    }

    static func offlineWindow(at date: Date) -> Window {
        var rule = DailyRule()
        rule.hour = 23
        rule.minute = 59
        let start = rule.calendar.startOfDay(for: date)
        let end = rule.followingDay(after: start)
        return Window(id: "local-\(Int(start.timeIntervalSince1970))", version: 0,
                      opens: start, deadline: end, expiry: end, zoneID: rule.zoneID, isTrip: false)
    }
}
