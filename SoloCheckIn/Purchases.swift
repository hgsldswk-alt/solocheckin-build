import Foundation
import StoreKit

@MainActor
final class Purchases: ObservableObject {
    static let proID = "com.hgsldswk.solocheckin.pro"
    static let trialID = "com.hgsldswk.solocheckin.trial"
    @Published private(set) var pro: Product?
    @Published private(set) var trial: Product?
    @Published private(set) var busy = false
    @Published var message: String?
    var onChange: (() async -> Void)?
    private var updates: Task<Void, Never>?

    func start() {
        guard !Launch.testing, !Launch.isFree, updates == nil else { return }
        updates = Task { [weak self] in
            await self?.syncEntitlements()
            for await result in Transaction.updates {
                guard !Task.isCancelled else { return }
                if case let .verified(transaction) = result,
                   [Self.proID, Self.trialID].contains(transaction.productID) {
                    await self?.syncEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    func load() async {
        guard !Launch.testing, !Launch.isFree, pro == nil || trial == nil else { return }
        do {
            let products = try await Product.products(for: [Self.proID, Self.trialID])
            pro = products.first { $0.id == Self.proID && $0.type == .nonConsumable }
            trial = products.first { $0.id == Self.trialID && $0.type == .nonConsumable && $0.price == 0 }
            if pro == nil { message = "purchase.unavailable" }
        } catch { message = "purchase.unavailable" }
    }

    func buy(_ product: Product?) async {
        guard !busy, let product else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case let .verified(transaction) = result else { throw LocalError.invalid }
                let id = transaction.productID
                let date = transaction.originalPurchaseDate
                let valid = transaction.revocationDate == nil
                _ = try await LocalStore.update {
                    if id == Self.proID { $0.entitlement.purchasedPro = valid }
                    if id == Self.trialID, valid {
                        $0.entitlement.trialClaimedAt = min(date, $0.entitlement.trialClaimedAt ?? date)
                    }
                }
                await transaction.finish()
                await onChange?()
            case .pending: message = "purchase.pending"
            case .userCancelled: break
            @unknown default: message = "purchase.unavailable"
            }
        } catch { message = "purchase.unavailable" }
    }

    func restore() async {
        guard !busy, !Launch.testing else { return }
        busy = true
        message = nil
        defer { busy = false }
        do {
            try await AppStore.sync()
            await syncEntitlements()
            message = "purchase.restored"
        } catch { message = "purchase.unavailable" }
    }

    private func syncEntitlements() async {
        var bought = false
        var claimed: Date?
        var uncertainPro = false
        for await result in Transaction.currentEntitlements {
            switch result {
            case .verified(let transaction):
                guard transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
                if transaction.productID == Self.proID { bought = true }
                if transaction.productID == Self.trialID {
                    claimed = min(claimed ?? transaction.originalPurchaseDate, transaction.originalPurchaseDate)
                }
            case .unverified(let transaction, _):
                if transaction.productID == Self.proID { uncertainPro = true }
            }
        }
        let value = bought, receipt = claimed, uncertain = uncertainPro
        _ = try? await LocalStore.update {
            if !uncertain { $0.entitlement.purchasedPro = value }
            if let receipt { $0.entitlement.trialClaimedAt = min($0.entitlement.trialClaimedAt ?? receipt, receipt) }
        }
        await onChange?()
    }
}
