import CoreImage
import Foundation
import XCTest

final class CoreTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testGraceUsesRealMinutesAndInclusiveCloudBoundary() throws {
        let now = date("2026-11-25T20:00:00+08:00")
        let rule = DailyRule(hour: 21, minute: 0, grace: 30, zoneID: "Asia/Shanghai")
        let window = try XCTUnwrap(Plan(rule: rule).windows(around: now).first { $0.opens <= now && $0.deadline > now })
        XCTAssertEqual(window.deadline, date("2026-11-25T13:00:00Z"))
        XCTAssertEqual(window.expiry, date("2026-11-25T13:30:00Z"))
        XCTAssertEqual(window.timing(at: window.deadline.addingTimeInterval(-1)), .early)
        XCTAssertEqual(window.timing(at: window.deadline), .grace)
        XCTAssertEqual(window.timing(at: window.expiry), .grace)
        XCTAssertEqual(window.timing(at: window.expiry.addingTimeInterval(1)), .overdue)
        XCTAssertTrue(Periods.receiverCovers(window, clicked: now, uploaded: window.expiry))
        XCTAssertFalse(Periods.receiverCovers(window, clicked: now, uploaded: window.expiry.addingTimeInterval(1)))
        XCTAssertFalse(Periods.receiverCovers(window, clicked: window.opens.addingTimeInterval(-1), uploaded: window.expiry))
    }

    func testSpringDSTSkipsToFirstValidMinuteAndFallUsesFirstOccurrence() throws {
        let spring = date("2026-03-08T12:00:00Z")
        let fall = date("2026-11-01T13:00:00Z")
        let rule = DailyRule(hour: 2, minute: 30, grace: 60, zoneID: "America/New_York")
        XCTAssertEqual(rule.deadline(on: spring), date("2026-03-08T07:00:00Z"))
        let fallRule = DailyRule(hour: 1, minute: 30, grace: 120, zoneID: "America/New_York")
        let window = try XCTUnwrap(Plan(rule: fallRule).windows(around: fall).first { fallRule.calendar.isDate($0.deadline, inSameDayAs: fall) })
        XCTAssertEqual(window.deadline, date("2026-11-01T05:30:00Z"))
        XCTAssertEqual(window.expiry, date("2026-11-01T07:30:00Z"))
        let tokyo = DailyRule(hour: 21, minute: 0, grace: 30, zoneID: "Asia/Tokyo")
        XCTAssertEqual(tokyo.deadline(on: fall), date("2026-11-01T12:00:00Z"))
    }

    func testMidnightGraceAndDuplicateWrites() throws {
        let now = date("2026-11-26T00:10:00+08:00")
        let yesterday = date("2026-11-25T23:50:00+08:00")
        var state = CheckInState()
        state.plan = PlanChange(current: Plan(rule: DailyRule(hour: 23, minute: 50, grace: 30, zoneID: "Asia/Shanghai")))
        state.enabled = true
        XCTAssertEqual(state.activeWindow(at: now)?.deadline, yesterday)
        let first = try XCTUnwrap(state.activeWindow(at: now))
        XCTAssertTrue(state.record(at: now))
        XCTAssertFalse(state.record(at: now.addingTimeInterval(1)))
        XCTAssertEqual(state.checks[first.id]?.clicked, now)
        XCTAssertEqual(state.distinctDays, ["2026-11-25"])
        XCTAssertNotEqual(state.activeWindow(at: now.addingTimeInterval(601))?.id, first.id)
    }

    func testTripAdjustsOverlappingDailyWindowsAndThenResumes() throws {
        let now = date("2026-11-25T12:00:00Z")
        let trip = Trip(starts: date("2026-11-25T16:00:00Z"), returns: date("2026-11-26T15:00:00Z"), grace: 60)
        let plan = Plan(rule: DailyRule(zoneID: "Etc/UTC"), trips: [trip])
        let window = plan.windows(around: now)
        XCTAssertFalse(window.contains { $0.deadline == date("2026-11-25T21:00:00Z") })
        XCTAssertEqual(window.first(where: \.isTrip)?.expiry, trip.expiry)
        let next = try XCTUnwrap(window.first { $0.deadline == date("2026-11-26T21:00:00Z") })
        XCTAssertEqual(next.opens, trip.expiry)
        var invalid = plan
        invalid.trips.append(Trip(starts: trip.starts, returns: trip.returns, grace: 30))
        XCTAssertFalse(invalid.valid)
    }

    func testChangedPlanKeepsPreviousWindowThroughMidnightGrace() {
        let date = self.date("2026-11-26T00:15:00Z")
        let old = Plan(rule: DailyRule(hour: 23, minute: 55, grace: 30, zoneID: "Etc/UTC"))
        let next = Plan(version: 2, effective: self.date("2026-11-26T00:00:00Z"), rule: DailyRule(zoneID: "Etc/UTC"))
        let windows = PlanChange(current: old, next: next).windows(around: date)
        XCTAssertEqual(Periods.target(in: windows, at: date)?.version, 1)
        XCTAssertEqual(Periods.target(in: windows, at: date.addingTimeInterval(660))?.version, 2)
        XCTAssertEqual(Set(windows.map(\.id)).count, windows.count)
    }

    func testPauseAndClockRollbackPreserveHistory() {
        let now = date("2026-11-25T14:00:00Z")
        let pause = Plan(rule: DailyRule(zoneID: "Etc/UTC"), pausedFrom: now, pausedUntil: now.addingTimeInterval(86_400))
        XCTAssertFalse(pause.windows(around: now).contains { $0.deadline > now && $0.deadline < pause.pausedUntil! })
        var state = CheckInState()
        state.record(at: now)
        state.maintain(at: now, uptime: 1000)
        state.maintain(at: now.addingTimeInterval(-3600), uptime: 1002)
        XCTAssertTrue(state.clockWarning)
        XCTAssertEqual(state.history.count, 1)
    }

    func testSettingTimeAfterFirstCheckInKeepsTheOriginalClick() {
        let now = date("2026-11-25T20:20:00Z")
        var state = CheckInState()
        XCTAssertTrue(state.record(at: now))
        XCTAssertTrue(state.changePlan(Plan(rule: DailyRule(zoneID: "Etc/UTC")), at: now))
        XCTAssertEqual(state.checkIn(at: now)?.clicked, now)
        XCTAssertFalse(state.record(at: now.addingTimeInterval(10)))
        XCTAssertEqual(state.history.count, 1)
    }

    func testCoverageStateNeverClaimsReadyBeforeAValidReceipt() {
        let now = date("2026-11-25T22:00:00Z")
        let plan = PlanChange(current: Plan())
        var link = Outgoing(alias: "Friend", partner: "Opaque id", linked: now, plan: plan)
        XCTAssertEqual(link.status(at: now), "status.invited")
        link.invitationAccepted = true
        XCTAssertEqual(link.status(at: now), "status.awaiting")
        let test = UUID()
        link.test = test
        link.ack = WindowReceipt(version: plan.current.version, confirmed: now, coveredUntil: now.addingTimeInterval(6 * 86_400),
                                 allowed: true, needsRevision: false, timeZone: "Etc/UTC", device: UUID(), coverageCount: 6)
        XCTAssertEqual(link.status(at: now), "status.test")
        link.ack?.tested = test
        XCTAssertEqual(link.status(at: now), "status.tested")
        XCTAssertEqual(link.status(at: now.addingTimeInterval(48 * 3600)), "status.refresh")
        link.ack?.needsRevision = true
        XCTAssertEqual(link.status(at: now), "status.refresh")
    }

    func testCodeRoundTripOptionalZoneAndMalformedFields() throws {
        let rule = DailyRule(hour: 5, minute: 7, grace: 120, zoneID: "Pacific/Auckland")
        XCTAssertEqual(try ShareCode.decode("\n" + ShareCode.encode(rule) + "\n"), rule)
        let utc = TimeZone(identifier: "Etc/UTC")!
        XCTAssertEqual(try ShareCode.decode(ShareCode.encode(rule, includeZone: false), localZone: utc).zoneID, "Etc/UTC")
        for invalid in ["SCI2:2100:30:", "SCI1:2400:30:", "SCI1:2160:30:", "SCI1:2100:10:", "SCI1:2100:30:!!", "SCI1:2100:30::invite", String(repeating: "x", count: 513)] {
            XCTAssertThrowsError(try ShareCode.decode(invalid))
        }
    }

    func testTrialExpiresAndRestoreUsesEarlierStart() {
        let now = date("2026-11-25T00:00:00Z")
        var entitlement = Entitlement(firstOpen: now.addingTimeInterval(-100 * 86_400), proStartedAt: now)
        XCTAssertTrue(entitlement.hasPro(at: now, free: false))
        XCTAssertTrue(entitlement.hasPro(at: entitlement.trialEnd.addingTimeInterval(-1), free: false))
        XCTAssertFalse(entitlement.hasPro(at: entitlement.trialEnd, free: false))
        entitlement.trialClaimedAt = now.addingTimeInterval(24 * 3600)
        XCTAssertEqual(entitlement.trialStart, now)
        entitlement.trialClaimedAt = now.addingTimeInterval(-24 * 3600)
        XCTAssertEqual(entitlement.trialStart, now.addingTimeInterval(-24 * 3600))
        let expired = entitlement.trialEnd
        XCTAssertTrue(entitlement.canAddContact(total: 0, at: expired))
        XCTAssertFalse(entitlement.canAddContact(total: 1, at: expired))
        XCTAssertFalse(entitlement.canAddTrip(total: 1, at: expired))
        entitlement.purchasedPro = true
        XCTAssertTrue(entitlement.canAddContact(total: 2, at: expired))
        XCTAssertFalse(entitlement.canAddContact(total: 3, at: expired))
        XCTAssertTrue(entitlement.canAddTrip(total: 1, at: expired))
    }

    func testExpiredStateCanStillCheckInAndDecodeExistingHistory() throws {
        let now = date("2026-11-25T00:00:00Z")
        var state = CheckInState()
        state.entitlement.firstOpen = now.addingTimeInterval(-35 * 86_400)
        XCTAssertFalse(state.entitlement.hasPro(at: now))
        XCTAssertTrue(state.record(at: now))
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CheckInState.self, from: data)
        XCTAssertEqual(decoded.history.first?.clicked, now)
    }

    func testQRReadsOfficialStoreURLAndLocalizationsUseBundle() throws {
        let expected = "https://apps.apple.com/app/id1234567890"
        let image = try XCTUnwrap(QR.image(expected, scale: 8))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let features = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertTrue(features.contains(expected))
        XCTAssertNotEqual(L.t("home.check"), "home.check")
    }
}
