import Foundation

struct CheckIn: Codable, Equatable, Identifiable {
    var id: String { window.id }
    let window: Window
    let clicked: Date
    let day: String
}

struct CloudCheckIn: Codable, Equatable {
    var entry: CheckIn
    let uploaded: Date
}

struct ZoneKey: Codable, Equatable, Hashable {
    var name: String
    var owner: String
}

struct WindowReceipt: Codable, Equatable {
    var version: Int
    var confirmed: Date
    var coveredUntil: Date?
    var allowed: Bool
    var needsRevision: Bool
    var timeZone: String
    var device: UUID
    var seen: String?
    var contacted: String?
    var tested: UUID?
    var coverageCount: Int
    var ended = false
}

struct Agreement: Codable, Equatable {
    var pair: UUID
    var alias: String
    var plan: PlanChange?
    var checkSummary: CloudCheckIn?
    var test: UUID?
    var receipt: WindowReceipt?
    var linked: Date
}

struct Outgoing: Codable, Identifiable {
    var id = UUID()
    var alias: String
    var partner: String
    var invite: URL?
    var linked: Date
    var plan: PlanChange
    var returnZone: ZoneKey?
    var ack: WindowReceipt?
    var test: UUID?
    var testSent: Date?
    var uploaded: [String: Date] = [:]
    var invitationAccepted = false
    var ended = false

    func status(at now: Date) -> String {
        if ended { return "status.ended" }
        guard let ack else { return (returnZone == nil && !invitationAccepted) ? "status.invited" : "status.awaiting" }
        if ack.ended { return "status.ended" }
        if !ack.allowed || ack.needsRevision || ack.confirmed > now.addingTimeInterval(600)
            || now.timeIntervalSince(ack.confirmed) >= 48 * 3600 {
            return "status.refresh"
        }
        if let next = plan.next, ack.version != next.version { return "status.waiting" }
        guard let covered = ack.coveredUntil, covered > now else { return "status.refresh" }
        if covered.timeIntervalSince(now) <= 48 * 3600 { return "status.short" }
        return test != nil && test == ack.tested ? "status.tested" : "status.test"
    }
}

struct Incoming: Codable, Identifiable {
    var id: UUID { agreement.pair }
    var zone: ZoneKey
    var source: String
    var agreement: Agreement
    var applied: PlanChange?
    var refreshed: Date?
    var entries: [String: CloudCheckIn] = [:]
    var cloudToken: Data?
    var phone = ""
    var returnURL: URL?
    var ownerDevice: UUID?
    var receipt: WindowReceipt?
    var scheduledTest: UUID?
    var failed = false
    var ended = false

    var lastCheck: CloudCheckIn? {
        (Array(entries.values) + [agreement.checkSummary].compactMap { $0 })
            .max { $0.entry.window.deadline < $1.entry.window.deadline }
    }

    func relevant(at now: Date) -> Window? {
        applied?.windows(around: now, before: 7).last { $0.expiry <= now }
    }
}

struct Revocation: Codable, Equatable {
    var zone: ZoneKey
    var shared: Bool
}

struct CheckInState: Codable {
    var generation = UUID()
    var entitlement = Entitlement()
    var plan = PlanChange(current: Plan())
    var enabled = false
    var nickname = ""
    var owner: String?
    var outgoing: [Outgoing] = []
    var incoming: [Incoming] = []
    var revoke: [Revocation] = []
    var device = UUID()
    var checks: [String: CheckIn] = [:]
    var personalKeys: Set<String> = []
    var seenMilestones: Set<Int> = []
    var distinctDays: Set<String> = []
    var actualUseDays: Set<String> = []
    var reviewedVersion: String?
    var alarmWanted = false
    var clockWall: Date?
    var clockUptime: TimeInterval?
    var clockWarning = false
    var firstFreeContact: UUID? { outgoing.first(where: { !$0.ended })?.id }

    func activeWindow(at now: Date) -> Window? {
        guard enabled else { return Periods.offlineWindow(at: now) }
        let windows = plan.windows(around: now)
        if let target = Periods.target(in: windows, at: now),
           target.expiry >= now || target.opens >= plan.current.rule.calendar.startOfDay(for: now) {
            return target
        }
        if let trip = windows.last(where: { $0.isTrip && $0.opens <= now && $0.expiry >= now }) { return trip }
        return Periods.offlineWindow(at: now)
    }

    func checkIn(at now: Date, late: Window? = nil) -> CheckIn? {
        guard let window = late ?? activeWindow(at: now) else { return nil }
        return checks[window.id] ?? checks.values.first {
            $0.window.version == 0 && $0.clicked >= window.opens && $0.clicked <= min(now, window.expiry)
        }
    }

    func lateWindow(at now: Date) -> Window? {
        guard enabled else { return nil }
        let eligible = ([plan] + outgoing.filter { !$0.ended }.map(\.plan))
            .flatMap { $0.windows(around: now, before: 2, after: 0) }
        let active = activeWindow(at: now)?.id
        return eligible.filter { window in
            window.id != active && window.expiry < now
                && window.expiry >= now.addingTimeInterval(-86_400) && !hasChecked(window, at: now)
        }.max { $0.deadline < $1.deadline }
    }

    func hasChecked(_ window: Window, at now: Date) -> Bool {
        checks[window.id] != nil || checks.values.contains {
            $0.window.version == 0 && $0.clicked >= window.opens && $0.clicked <= min(now, window.expiry)
        }
    }

    @discardableResult
    mutating func record(at now: Date, late: Window? = nil) -> Bool {
        guard let active = late ?? activeWindow(at: now), active.opens <= now,
              checkIn(at: now, late: active) == nil else { return false }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: active.zoneID)
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: active.isTrip ? now : active.deadline.addingTimeInterval(active.version == 0 ? -1 : 0))
        checks[active.id] = CheckIn(window: active, clicked: now, day: day)
        personalKeys.insert(active.id)
        distinctDays.insert(day)
        formatter.timeZone = .current
        actualUseDays.insert(formatter.string(from: now))
        guard late == nil else { return true }
        for link in outgoing where !link.ended && now >= link.linked {
            var variants = [link.plan]
            if link.plan.next != nil { variants.append(PlanChange(current: link.plan.current)) }
            for variant in variants {
                let windows = variant.windows(around: now)
                guard let window = Periods.target(in: windows, at: now),
                      window.id != active.id, window.opens <= now,
                      window.expiry >= now || window.opens >= variant.current.rule.calendar.startOfDay(for: now),
                      checks[window.id] == nil else { continue }
                checks[window.id] = CheckIn(window: window, clicked: now, day: day)
            }
        }
        return true
    }

    mutating func maintain(at now: Date, uptime: TimeInterval) {
        if let wall = clockWall, let lastUptime = clockUptime, uptime >= lastUptime,
           abs(now.timeIntervalSince(wall) - (uptime - lastUptime)) > 600 { clockWarning = true }
        clockWall = now
        clockUptime = uptime
        guard !clockWarning else { return }
        let cutoff = now.addingTimeInterval(-90 * 86_400)
        checks = checks.filter { $0.value.clicked >= cutoff }
        personalKeys.formIntersection(checks.keys)
    }

    mutating func changePlan(_ proposed: Plan, at now: Date) -> Bool {
        var updated = proposed
        let revisions = [plan.current.version, plan.next?.version ?? 0] + outgoing.map { $0.plan.next?.version ?? $0.plan.current.version }
        updated.version = (revisions.max() ?? 1) + 1
        let oldRule = (plan.next.flatMap { $0.effective <= now ? $0 : nil } ?? plan.current).rule
        updated.effective = outgoing.contains { !$0.ended } ? oldRule.followingDay(after: now) : .distantPast
        guard updated.valid else { return false }
        if enabled && outgoing.contains(where: { !$0.ended }) {
            let previous = plan.next.flatMap { $0.effective <= now ? $0 : nil } ?? plan.current
            plan = PlanChange(current: previous, next: updated)
            for index in outgoing.indices where !outgoing[index].ended {
                let old = outgoing[index].plan
                let confirmed = old.next.flatMap { outgoing[index].ack?.version == $0.version && $0.effective <= now ? $0 : nil } ?? old.current
                outgoing[index].plan = PlanChange(current: confirmed, next: updated)
            }
        } else {
            plan = PlanChange(current: updated)
        }
        enabled = true
        return true
    }

    var history: [CheckIn] {
        personalKeys.compactMap { checks[$0] }.sorted { $0.clicked > $1.clicked }
    }
}
