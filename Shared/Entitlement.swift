import Foundation

struct Entitlement: Codable, Equatable {
    var firstOpen = Date()
    var proStartedAt: Date?
    var trialClaimedAt: Date?
    var purchasedPro = false

    var trialStart: Date {
        let localStart = proStartedAt ?? firstOpen
        return min(localStart, trialClaimedAt ?? localStart)
    }

    var trialEnd: Date { trialStart.addingTimeInterval(30 * 86_400) }
    func hasPro(at date: Date, free: Bool = Launch.isFree) -> Bool {
        free || purchasedPro || (date >= trialStart && date < trialEnd)
    }
    func canAddContact(total: Int, at date: Date) -> Bool { total < (hasPro(at: date) ? 3 : 1) }
    func canAddTrip(total: Int, at date: Date) -> Bool { total < (hasPro(at: date) ? 12 : 1) }
}
