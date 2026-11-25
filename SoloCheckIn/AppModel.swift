import CloudKit
import Foundation
import UIKit
import WidgetKit

enum Route: Hashable {
    case time, contacts, travel, pause, invite, test(UUID), incoming(UUID), number(UUID)
    case history, share(Int?), codes, paywall, privacy
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published private(set) var data = CheckInState()
    @Published private(set) var ready = false
    @Published private(set) var checking = false
    @Published private(set) var refreshing = false
    @Published private(set) var capability = "notice.disabled"
    @Published var error: String?
    @Published var message: String?
    @Published var preview: SharePreview?
    @Published var share: SharePayload?
    @Published var sharedForTesting = false
    @Published var tab = 0
    @Published var homePath: [Route] = []
    @Published var receivePath: [Route] = []
    @Published var settingsPath: [Route] = []
    @Published var openedWindow: String?
    @Published var reviewCandidate = false
    let notices = Notifications()
    let purchases = Purchases()
    private lazy var sync = SyncEngine(notices: notices)
    private var startup: Task<Void, Never>?
    private var refreshJob: Task<Void, Never>?
    private var needsRefresh = false
    private var storageFailures = 0
    var now: Date { Launch.testing ? Fixtures.date : Date() }
    var pro: Bool { data.entitlement.hasPro(at: now) }
    var rule: DailyRule { (data.plan.next ?? data.plan.current).rule }
    var hasNotificationRoute: Bool { openedWindow != nil || !receivePath.isEmpty && tab == 1 }

    func start() async {
        if let startup { await startup.value; return }
        let job = Task { @MainActor in
            do {
                let testing = Launch.testing
                let reset = Launch.arguments.contains("-reset")
                let startingDate = now
                let paidStart = testing || Launch.isFree ? startingDate : await TrialClock.firstPaidLaunch(at: startingDate)
                data = try await LocalStore.update { stored in
                    if testing && reset { stored = Fixtures.state() }
                    if !Launch.isFree && !testing {
                        stored.entitlement.proStartedAt = min(stored.entitlement.proStartedAt ?? paidStart, paidStart)
                    }
                }.0
                ready = true
                if Launch.testing && Launch.arguments.contains("-paywall") {
                    tab = 2
                    settingsPath = [.paywall]
                } else if Launch.testing && Launch.arguments.contains("-reminder") {
                    openedWindow = data.activeWindow(at: now)?.id
                }
                if Launch.testing && Launch.arguments.contains("-accept-invite") {
                    preview = Fixtures.preview()
                }
                notices.register()
                purchases.onChange = { [weak self] in await self?.reload() }
                purchases.start()
                if !Launch.testing {
                    Task { await refresh() }
                } else {
                    await notices.personal(data, now: now)
                    capability = notices.capability
                }
            } catch { self.error = "error.storage" }
        }
        startup = job
        await job.value
        if !ready { startup = nil }
    }

    func reload() async {
        do { data = try await LocalStore.read() } catch { self.error = "error.storage" }
    }

    func refresh() async {
        guard ready else { return }
        if let refreshJob {
            needsRefresh = true
            await refreshJob.value
            return
        }
        refreshing = true
        let task = Task { @MainActor in
            repeat {
                needsRefresh = false
                do {
                    if !Launch.testing && (data.outgoing.contains { !$0.ended } || !data.incoming.isEmpty) {
                        registerPush()
                    }
                    _ = try await sync.refresh(now: now)
                    await reload()
                    capability = notices.capability
                    storageFailures = 0
                } catch {
                    storageFailures += 1
                    if storageFailures == 1, !(error is LocalError) { self.error = "error.storage" }
                }
            } while needsRefresh && !Task.isCancelled
        }
        refreshJob = task
        await task.value
        refreshJob = nil
        refreshing = false
    }

    private var requestedPush = false
    private func registerPush() {
        guard !requestedPush else { return }
        UIApplication.shared.registerForRemoteNotifications()
        requestedPush = true
    }

    @discardableResult
    func check(late: Window? = nil, notificationID: String? = nil) async -> Bool {
        if !ready { await start() }
        guard ready, !checking else { return false }
        checking = true
        defer { checking = false }
        let date = now
        do {
            let (updated, created) = try await LocalStore.update { state in
                if !Launch.testing { state.maintain(at: date, uptime: ProcessInfo.processInfo.systemUptime) }
                if let notificationID,
                   state.activeWindow(at: date)?.id != notificationID {
                    return false
                }
                return state.record(at: date, late: late)
            }
            data = updated
            guard created else { return false }
            openedWindow = nil
            if !Launch.testing {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                WidgetCenter.shared.reloadAllTimelines()
            }
            if late == nil, !updated.clockWarning, updated.actualUseDays.count >= 3,
               let check = updated.checkIn(at: date), check.window.timing(at: date) != .overdue {
                reviewCandidate = true
            }
            await notices.personal(data, now: date)
            capability = notices.capability
            if !Launch.testing && data.owner != nil { Task { await refresh() } }
            return true
        } catch {
            self.error = "error.storage"
            return false
        }
    }

    func save(plan: Plan) async -> Bool {
        let date = now
        do {
            data = try await LocalStore.update {
                guard $0.changePlan(plan, at: date) else { throw LocalError.invalid }
            }.0
            if !Launch.testing { WidgetCenter.shared.reloadAllTimelines() }
            await notices.personal(data, now: date)
            capability = notices.capability
            message = data.outgoing.contains { !$0.ended } ? "status.waitingNote" : "status.saved"
            if data.owner != nil { Task { await refresh() } }
            return true
        } catch { self.error = "error.plan"; return false }
    }

    func enableAlarm() async {
        let enabled: Bool
        if data.alarmWanted { enabled = false } else { enabled = await StrongAlarm.authorize() }
        await change { $0.alarmWanted = enabled }
        await notices.personal(data, now: now)
        capability = notices.capability
    }

    func invite(address: String, alias: String, nickname: String) async -> Bool {
        guard data.entitlement.canAddContact(total: data.outgoing.filter { !$0.ended }.count, at: now) else {
            homePath.append(.paywall)
            return false
        }
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String(alias.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        let name = String(nickname.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard !label.isEmpty, !name.isEmpty, !cleaned.isEmpty, cleaned.count <= 254 else { self.error = "error.invite"; return false }
        let date = now
        do {
            let owner: String
            let partner: String
            if Launch.testing {
                owner = "fixture-me"
                partner = "fixture-\(cleaned)"
            } else {
                owner = try await sync.identity(allowFirst: true)
                partner = try await sync.cloud.participant(address: cleaned)
            }
            guard partner != owner else { throw LocalError.invalid }
            let (state, link) = try await LocalStore.update { state in
                let links = state.outgoing.filter { !$0.ended }
                guard !links.contains(where: { $0.partner == partner }),
                      state.entitlement.canAddContact(total: links.count, at: date) else { throw LocalError.invalid }
                if !state.enabled {
                    state.enabled = true
                    state.plan.current.rule = DailyRule()
                }
                state.nickname = name
                var invitationPlan = state.plan
                if state.checkIn(at: date) != nil {
                    invitationPlan.current.effective = max(invitationPlan.current.effective, invitationPlan.current.rule.followingDay(after: date))
                    if invitationPlan.next?.effective == invitationPlan.current.effective,
                       let next = invitationPlan.next { invitationPlan = PlanChange(current: next) }
                }
                let link = Outgoing(alias: label, partner: partner, linked: date, plan: invitationPlan)
                state.outgoing.append(link)
                return link
            }
            data = state
            await notices.personal(state, now: date)
            return await resend(link.id)
        } catch { self.error = "error.invite"; return false }
    }

    @discardableResult
    func resend(_ id: UUID) async -> Bool {
        guard let link = data.outgoing.first(where: { $0.id == id && !$0.ended }) else { return false }
        do {
            let url: URL
            if Launch.testing { url = URL(string: "https://www.icloud.com/share/solo-fixture")! }
            else if let owner = data.owner {
                let value = Agreement(pair: link.id, alias: data.nickname, plan: link.plan, linked: link.linked)
                url = try await sync.cloud.invitation(zone: .sender(id), value: value, partner: link.partner, account: owner)
            } else { throw LocalError.unavailable }
            data = try await LocalStore.update {
                guard let i = $0.outgoing.firstIndex(where: { $0.id == id && !$0.ended }) else { throw LocalError.stale }
                $0.outgoing[i].invite = url
            }.0
            var items: [Any] = [L.t("contacts.invitationText"), url]
            if let storeURL = ShareCard.storeURL { items.append(storeURL) }
            requestShare(items)
            return true
        } catch { self.error = "error.invite"; return false }
    }

    func show(_ metadata: CKShare.Metadata) async {
        await start()
        do {
            let item = try Cloud.preview(metadata)
            if item.isReturn {
                guard data.outgoing.contains(where: { $0.id == item.pair && $0.partner == item.owner && !$0.ended }) else {
                    throw LocalError.invalid
                }
            }
            preview = item
        } catch { self.error = "error.link" }
    }

    func open(_ url: URL) async {
        if url.scheme == "solocheckin" && url.host == "check" {
            tab = 0
            homePath = []
        } else if url.isFileURL && url.pathExtension.lowercased() == ShareCode.fileExtension {
            await start()
            tab = 2
            pendingCodeFile = url
            settingsPath = [.codes]
        } else if url.scheme == "https", let host = url.host?.lowercased(),
                  host == "icloud.com" || host.hasSuffix(".icloud.com") {
            do {
                let item = try await sync.cloud.preview(url: url)
                if let metadata = item.metadata { await show(metadata) }
            } catch { self.error = "error.link" }
        }
    }

    @Published var pendingCodeFile: URL?
    @Published var pendingCodeText: String?

    func accept(_ item: SharePreview) async -> Bool {
        if Launch.testing {
            await change { stored in
                if !stored.incoming.contains(where: { $0.id == item.pair }) {
                    stored.incoming.append(Fixtures.incoming(device: stored.device))
                }
            }
            preview = nil
            tab = 1
            receivePath = [.incoming(item.pair)]
            return true
        }
        do {
            let owner = try await sync.identity(allowFirst: true)
            let base = try await LocalStore.read()
            if item.isReturn {
                guard base.outgoing.contains(where: { $0.id == item.pair && $0.partner == item.owner && !$0.ended }),
                      base.outgoing.first(where: { $0.id == item.pair })?.returnZone.map({ $0 == item.zone }) ?? true
                else { throw LocalError.invalid }
            }
            let value = try await sync.cloud.accept(item, account: owner)
            if !item.isReturn { await notices.allow() }
            data = try await sync.update(base) { state in
                if item.isReturn {
                    guard let i = state.outgoing.firstIndex(where: { $0.id == item.pair && $0.partner == item.owner && !$0.ended }) else {
                        throw LocalError.invalid
                    }
                    state.outgoing[i].returnZone = item.zone
                    state.outgoing[i].ack = value.receipt
                } else if !state.incoming.contains(where: { $0.id == item.pair }) {
                    guard state.incoming.count < 24 else { throw LocalError.busy }
                    state.incoming.append(Incoming(zone: item.zone, source: item.owner, agreement: value))
                }
            }.0
            preview = nil
            if item.isReturn {
                tab = 0
                homePath = [.contacts]
            } else {
                tab = 1
                receivePath = [.incoming(item.pair)]
            }
            await refresh()
            return true
        } catch { self.error = "error.link"; return false }
    }

    func returnReceipt(_ id: UUID, takingOver: Bool = false) async {
        if Launch.testing {
            requestShare([L.t("receive.receiptText")])
            return
        }
        guard let item = data.incoming.first(where: { $0.id == id }), let owner = data.owner else { return }
        do {
            let date = now
            let base = try await LocalStore.read()
            let value = WindowReceipt(version: 0, confirmed: date, allowed: false, needsRevision: true,
                                      timeZone: TimeZone.current.identifier, device: base.device, coverageCount: 0)
            if takingOver {
                try await sync.cloud.claim(value, pair: id, account: owner)
                await change {
                    if let index = $0.incoming.firstIndex(where: { $0.id == id }) {
                        $0.incoming[index].receipt = value
                        $0.incoming[index].ownerDevice = base.device
                        $0.incoming[index].scheduledTest = nil
                    }
                }
            }
            guard takingOver || item.ownerDevice == nil || item.ownerDevice == base.device else { throw LocalError.stale }
            let ack = takingOver ? value : (item.receipt ?? value)
            let agreement = Agreement(pair: id, alias: data.nickname, receipt: ack, linked: item.agreement.linked)
            let url = try await sync.cloud.invitation(zone: .receiver(id), value: agreement, partner: item.source, account: owner)
            await change { state in
                if let i = state.incoming.firstIndex(where: { $0.id == id }) { state.incoming[i].returnURL = url }
            }
            await refresh()
            requestShare([L.t("receive.receiptText"), url])
        } catch { self.error = "error.link" }
    }

    func test(_ id: UUID) async -> Bool {
        let now = now
        do {
            data = try await LocalStore.update {
                guard let index = $0.outgoing.firstIndex(where: { $0.id == id && !$0.ended && $0.invite != nil }),
                      Launch.testing || $0.outgoing[index].returnZone != nil else { throw LocalError.notReady }
                $0.outgoing[index].test = UUID()
                $0.outgoing[index].testSent = now
            }.0
            message = "contacts.testQueued"
            Task { await refresh() }
            return true
        } catch { self.error = "error.test"; return false }
    }

    func ack(_ id: UUID, test: Bool, window: String? = nil) async {
        let now = now
        do {
            data = try await LocalStore.update { state in
                guard let i = state.incoming.firstIndex(where: { $0.id == id }),
                      state.incoming[i].receipt?.device == state.device else { throw LocalError.notReady }
                if test {
                    guard let event = state.incoming[i].agreement.test, state.incoming[i].scheduledTest == event,
                          state.incoming[i].receipt?.allowed == true else { throw LocalError.notReady }
                    state.incoming[i].receipt?.tested = event
                } else {
                    guard let key = window ?? state.incoming[i].relevant(at: now)?.id else { throw LocalError.invalid }
                    state.incoming[i].receipt?.contacted = key
                }
            }.0
            message = test ? "receive.testSaved" : "receive.contactSaved"
            Task { await refresh() }
        } catch { self.error = "error.test" }
    }

    func disconnect(_ id: UUID, incoming: Bool) async -> Bool {
        do {
            data = try await LocalStore.update { state in
                if incoming, let i = state.incoming.firstIndex(where: { $0.id == id }) {
                    state.revoke += [Revocation(zone: .receiver(id), shared: false), Revocation(zone: state.incoming[i].zone, shared: true)]
                    state.incoming.remove(at: i)
                } else if let i = state.outgoing.firstIndex(where: { $0.id == id }) {
                    state.revoke.append(Revocation(zone: .sender(id), shared: false))
                    if let back = state.outgoing[i].returnZone { state.revoke.append(Revocation(zone: back, shared: true)) }
                    state.outgoing[i].ended = true
                    state.outgoing[i].invite = nil
                    state.outgoing[i].partner = ""
                    state.outgoing[i].uploaded = [:]
                    state.outgoing[i].returnZone = nil
                    state.outgoing[i].ack = nil
                }
                if Launch.testing { state.revoke = [] }
            }.0
            await notices.remove(id)
            if data.owner != nil { Task { await refresh() } }
            return true
        } catch { self.error = "error.storage"; return false }
    }

    func clear() async {
        do {
            data = try await LocalStore.update { state in
                var clean = CheckInState()
                clean.entitlement = state.entitlement
                clean.owner = state.owner
                clean.reviewedVersion = state.reviewedVersion
                clean.revoke = state.revoke
                for link in state.outgoing {
                    clean.revoke.append(Revocation(zone: .sender(link.id), shared: false))
                    if let zone = link.returnZone { clean.revoke.append(Revocation(zone: zone, shared: true)) }
                }
                for item in state.incoming {
                    clean.revoke += [Revocation(zone: .receiver(item.id), shared: false), Revocation(zone: item.zone, shared: true)]
                }
                if Launch.testing { clean.revoke = [] }
                state = clean
            }.0
            await notices.clear()
            await ExportFile.clear()
            if !Launch.testing { WidgetCenter.shared.reloadAllTimelines() }
            message = "settings.cleared"
            Task { await refresh() }
        } catch { self.error = "error.storage" }
    }

    func change(_ block: @escaping @Sendable (inout CheckInState) throws -> Void) async {
        do { data = try await LocalStore.update(block).0 } catch { self.error = "error.storage" }
    }

    func openNotice(_ info: [AnyHashable: Any], isAction: Bool) async {
        await start()
        let window = info["window"] as? String
        if isAction {
            guard let window else { return }
            _ = await check(notificationID: window)
            if data.owner != nil { await refresh() }
            return
        }
        openedWindow = window
        if let pair = (info["pair"] as? String).flatMap(UUID.init(uuidString:)) {
            tab = 1
            receivePath = [.incoming(pair)]
        } else {
            tab = 0
            homePath = []
        }
        Task { await refresh() }
    }

    func requestShare(_ items: [Any]) {
        if Launch.testing { sharedForTesting = true }
        else { share = SharePayload(items: items) }
    }

    func mayReview(version: String) async -> Bool {
        guard !Launch.testing && reviewCandidate && !hasNotificationRoute && tab == 0 && homePath.isEmpty
                && message == nil && share == nil && preview == nil && error == nil && !data.clockWarning
                && data.actualUseDays.count >= 3 else { return false }
        do {
            let (updated, decision) = try await LocalStore.update {
                guard $0.reviewedVersion != version else { return false }
                $0.reviewedVersion = version
                return true
            }
            data = updated
            reviewCandidate = false
            return decision
        } catch { return false }
    }
}
