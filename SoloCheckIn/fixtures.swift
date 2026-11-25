import Foundation

enum Fixtures {
    static let date = ISO8601DateFormatter().date(from: "2026-11-25T20:58:00+08:00")!
    static let friend = UUID(uuidString: "52114E30-5DA1-412F-A9A7-86813CB3A619")!
    static let sender = UUID(uuidString: "C867F021-3874-44C5-AA55-86F472D43CEB")!

    static func state() -> CheckInState {
        var state = CheckInState()
        state.entitlement.firstOpen = date.addingTimeInterval(Launch.arguments.contains("-expired") ? -31 * 86_400 : 0)
        if Launch.arguments.contains("-expired") {
            state.record(at: date.addingTimeInterval(-86_400))
        }
        guard Launch.arguments.contains("-demo") else { return state }
        let plan = Plan(rule: DailyRule(hour: 21, minute: 0, grace: 30, zoneID: "Asia/Shanghai"))
        state.plan = PlanChange(current: plan)
        state.enabled = true
        state.nickname = L.t("demo.sender")
        let linked = date.addingTimeInterval(-7 * 86_400)
        let demoAck = WindowReceipt(version: plan.version, confirmed: date.addingTimeInterval(-1800),
                                    coveredUntil: date.addingTimeInterval(6 * 86_400), allowed: true,
                                    needsRevision: false, timeZone: "Asia/Tokyo", device: UUID(), coverageCount: 7)
        let test = UUID()
        var ack = demoAck
        ack.tested = test
        state.outgoing = [Outgoing(id: friend, alias: L.t("demo.contact"), partner: "fixture",
                                  invite: URL(string: "https://www.icloud.com/share/solo-fixture"),
                                  linked: linked, plan: state.plan, ack: ack, test: test)]
        state.incoming = [incoming(device: state.device, receipt: demoAck, hasReturn: true)]
        if Launch.arguments.contains("-trip-demo") {
            let trip = Trip(starts: date.addingTimeInterval(86_400), returns: date.addingTimeInterval(100_800), grace: 30)
            state.plan.current.trips = [trip]
            state.outgoing[0].plan = state.plan
        }
        if Launch.arguments.contains("-checked") {
            let clicked = date.addingTimeInterval(-57 * 60)
            state.record(at: clicked)
            if let check = state.checkIn(at: clicked) {
                state.outgoing[0].uploaded[check.id] = clicked.addingTimeInterval(2)
                state.outgoing[0].ack?.seen = check.id
            }
        }
        return state
    }

    static func incoming(device: UUID, receipt: WindowReceipt? = nil, hasReturn: Bool = false) -> Incoming {
        var remotePlan = Plan(rule: DailyRule(hour: 21, minute: 0, grace: 30, zoneID: "Asia/Shanghai"))
        remotePlan.rule.hour = 19
        let event = UUID()
        let linked = date.addingTimeInterval(-7 * 86_400)
        let value = Agreement(pair: sender, alias: L.t("demo.sender"), plan: PlanChange(current: remotePlan),
                              test: event, linked: linked)
        let yesterday = remotePlan.windows(around: date).first!
        let check = CheckIn(window: yesterday, clicked: yesterday.deadline.addingTimeInterval(-3600), day: "2026-11-24")
        var incoming = Incoming(zone: ZoneKey(name: "fixture", owner: "fixture"), source: "fixture", agreement: value,
                                applied: value.plan, refreshed: date, entries: [check.id: CloudCheckIn(entry: check, uploaded: check.clicked)],
                                returnURL: hasReturn ? URL(string: "https://www.icloud.com/share/solo-fixture") : nil, ownerDevice: device,
                                receipt: receipt, scheduledTest: hasReturn ? event : nil)
        incoming.receipt?.device = device
        return incoming
    }

    static func preview() -> SharePreview {
        SharePreview(pair: sender, zone: ZoneKey(name: "fixture", owner: "fixture"), owner: "fixture",
                     title: L.t("demo.sender"), isReturn: false, metadata: nil)
    }
}
