import CloudKit
import Foundation
import UserNotifications

@MainActor
final class SyncEngine {
    let cloud = Cloud.shared
    let notices: Notifications
    private var subscribedAccount: String?

    init(notices: Notifications) { self.notices = notices }

    func identity(allowFirst: Bool) async throws -> String {
        let owner = try await cloud.account()
        let stored = try await LocalStore.read()
        if let old = stored.owner, old != owner {
            _ = try await resetCloud(stored, owner: owner)
        } else if stored.owner == nil, allowFirst {
            _ = try await update(stored) { $0.owner = owner }
        }
        return owner
    }

    private func resetCloud(_ base: CheckInState, owner: String?) async throws -> CheckInState {
        await notices.clear()
        subscribedAccount = nil
        return try await update(base) { state in
            state.owner = owner
            state.outgoing = []
            state.incoming = []
            state.revoke = []
            state.device = UUID()
            state.generation = UUID()
        }.0
    }

    func update<T: Sendable>(_ base: CheckInState, _ body: @escaping @Sendable (inout CheckInState) throws -> T) async throws -> (CheckInState, T) {
        try await LocalStore.update {
            guard $0.generation == base.generation else { throw LocalError.stale }
            return try body(&$0)
        }
    }

    func refresh(now: Date) async throws -> CheckInState {
        var state = try await LocalStore.update { $0.maintain(at: now, uptime: ProcessInfo.processInfo.systemUptime) }.0
        await notices.personal(state, now: now)
        if Launch.testing { return state }
        guard let bound = state.owner, !state.outgoing.filter({ !$0.ended }).isEmpty
                || !state.incoming.isEmpty || !state.revoke.isEmpty else { return state }
        let account: String
        do { account = try await identity(allowFirst: false) }
        catch LocalError.signedOut {
            state = try await resetCloud(state, owner: nil)
            await notices.personal(state, now: now)
            return state
        }
        catch {
            return try await update(state) { data in
                for index in data.incoming.indices { data.incoming[index].failed = true }
            }.0
        }
        guard bound == account else {
            state = try await LocalStore.read()
            await notices.personal(state, now: now)
            return state
        }
        if subscribedAccount != account && (!state.outgoing.isEmpty || !state.incoming.isEmpty) {
            do { try await cloud.subscribe(); subscribedAccount = account } catch { /* Foreground reconciliation continues. */ }
        }
        for revocation in state.revoke {
            do {
                try await cloud.revoke(revocation, account: account)
                _ = try await update(state) { $0.revoke.removeAll { $0 == revocation } }
            } catch { continue }
        }
        guard !state.clockWarning else { return state }
        for link in state.outgoing where !link.ended && link.invite != nil {
            await publish(link, base: state, now: now, account: account)
        }
        var proposals: [Incoming] = []
        for item in state.incoming where !item.ended {
            if let updated = await readIncoming(item, base: state, account: account, now: now) {
                proposals.append(updated)
            }
        }
        try await apply(proposals, base: state, account: account, now: now)
        state = try await LocalStore.read()
        await notices.personal(state, now: now)
        return state
    }

    private func publish(_ link: Outgoing, base: CheckInState, now: Date, account: String) async {
        let zone = ZoneKey.sender(link.id)
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let candidates = base.checks.values.filter {
            $0.clicked >= link.linked && $0.window.expiry >= cutoff && $0.window.version > 0
                && !base.clockWarning && base.validForLink($0, link: link)
        }.sorted { $0.clicked < $1.clicked }
        do {
            var uploaded = link.uploaded
            for check in candidates where uploaded[check.id] == nil {
                do {
                    uploaded[check.id] = try await cloud.upload(check, pair: link.id, account: account)
                } catch { continue }
            }
            if uploaded != link.uploaded {
                let successful = uploaded
                _ = try await update(base) { state in
                    guard let index = state.outgoing.firstIndex(where: { $0.id == link.id && !$0.ended }) else {
                        throw LocalError.stale
                    }
                    state.outgoing[index].uploaded = successful
                    if candidates.contains(where: { check in
                        successful[check.id].map { check.clicked.timeIntervalSince($0) > 600 } ?? false
                    }) { state.clockWarning = true }
                }
            }
            let current = try await cloud.read(zone, owned: true)
            let additions = candidates.compactMap { check in uploaded[check.id].map { CloudCheckIn(entry: check, uploaded: $0) } }
            let newest = ([current.checkSummary].compactMap { $0 } + additions)
                .max { $0.entry.window.deadline < $1.entry.window.deadline }
            let expired = uploaded.keys.filter { id in
                base.checks[id].map { $0.window.expiry < cutoff } ?? (uploaded[id]! < cutoff)
            }
            try await cloud.newestEntry(zone, deleting: expired, account: account)
            expired.forEach { uploaded.removeValue(forKey: $0) }
            let newUploads = uploaded
            let latest = try await LocalStore.read()
            guard latest.generation == base.generation,
                  let fresh = latest.outgoing.first(where: { $0.id == link.id && !$0.ended }) else { return }
            let data = Agreement(pair: fresh.id, alias: latest.nickname, plan: fresh.plan, checkSummary: newest,
                                 test: fresh.test, linked: fresh.linked)
            try await cloud.write(data, zone: zone, account: account)
            var receipt: WindowReceipt?
            var remoteEnded = false
            if let returnZone = fresh.returnZone {
                do {
                    let value = try await cloud.read(returnZone)
                    guard value.pair == link.id, value.plan == nil else { throw LocalError.invalid }
                    receipt = value.receipt
                    remoteEnded = receipt?.ended == true
                } catch let error as CKError where Cloud.gone(error) { remoteEnded = true }
            }
            let ack = receipt
            let ended = remoteEnded
            let accepted: Bool
            if fresh.returnZone != nil || fresh.invitationAccepted { accepted = true }
            else { accepted = (try? await cloud.invitationAccepted(pair: fresh.id, partner: fresh.partner)) ?? false }
            _ = try await update(base) { state in
                guard let i = state.outgoing.firstIndex(where: { $0.id == link.id && !$0.ended }) else { return }
                state.outgoing[i].uploaded = newUploads
                state.outgoing[i].invitationAccepted = accepted
                if let ack, ack.confirmed >= (state.outgoing[i].ack?.confirmed ?? .distantPast) {
                    state.outgoing[i].ack = ack
                }
                if ended {
                    state.revoke.append(Revocation(zone: zone, shared: false))
                    if let back = state.outgoing[i].returnZone { state.revoke.append(Revocation(zone: back, shared: true)) }
                    state.outgoing[i].ended = true
                    state.outgoing[i].invite = nil
                    state.outgoing[i].partner = ""
                    state.outgoing[i].uploaded = [:]
                }
            }
        } catch {
        }
    }

    private func readIncoming(_ item: Incoming, base: CheckInState, account: String, now: Date) async -> Incoming? {
        var incoming = item
        do {
            let value = try await cloud.read(item.zone)
            guard value.pair == item.id, value.plan != nil, value.receipt == nil else { throw LocalError.invalid }
            incoming.agreement = value
            let cutoff = now.addingTimeInterval(-7 * 86_400)
            let changes = try await cloud.changes(item.zone, since: cutoff, entries: item.entries, tokenData: item.cloudToken)
            incoming.cloudToken = changes.token
            incoming.entries = changes.entries.filter { _, record in
                record.entry.clicked >= value.linked && record.entry.clicked >= record.entry.window.opens
                    && record.entry.clicked <= record.uploaded.addingTimeInterval(600)
            }
            if let summary = value.checkSummary, summary.entry.window.expiry >= now.addingTimeInterval(-7 * 86_400),
               summary.entry.clicked >= value.linked, summary.entry.clicked >= summary.entry.window.opens,
               summary.entry.clicked <= summary.uploaded.addingTimeInterval(600),
               incoming.entries[summary.entry.id] == nil { incoming.entries[summary.entry.id] = summary }
            incoming.refreshed = now
            incoming.failed = false
            let seed = WindowReceipt(version: 0, confirmed: now, coveredUntil: nil, allowed: false, needsRevision: true,
                                     timeZone: TimeZone.current.identifier, device: base.device, coverageCount: 0)
            let owned = try await cloud.receiverClaim(seed, pair: item.id, linked: value.linked, account: account)
            guard owned.pair == item.id, let remote = owned.receipt else { throw LocalError.invalid }
            incoming.ownerDevice = remote.device
            guard remote.device == base.device else {
                await notices.remove(item.id)
                incoming.applied = nil
                incoming.receipt = remote
                incoming.scheduledTest = nil
                _ = try await merge(incoming, base: base)
                return nil
            }
            if remote.confirmed > (incoming.receipt?.confirmed ?? .distantPast) {
                incoming.receipt = remote
            }
            return incoming
        } catch let error as CKError where Cloud.gone(error) {
            await notices.remove(item.id)
            _ = try? await update(base) { state in
                guard let i = state.incoming.firstIndex(where: { $0.id == item.id && !$0.ended }) else { return }
                state.revoke += [Revocation(zone: .receiver(item.id), shared: false), Revocation(zone: item.zone, shared: true)]
                state.incoming.remove(at: i)
            }
        } catch {
            incoming.failed = true
            _ = try? await merge(incoming, base: base)
        }
        return nil
    }

    private func apply(_ incoming: [Incoming], base: CheckInState, account: String, now: Date) async throws {
        guard !incoming.isEmpty else { return }
        let allowed = await notices.allowed()
        let proposals = incoming.map { item in
            (item: item, proposal: acceptable(item, now: now), previous: item.applied)
        }
        let staleIDs = Set(proposals.flatMap { proposal in
            proposal.item.entries.keys.map { Notice.prefix(proposal.item.id) + $0 }
        })
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: Array(staleIDs))
        let preserving = proposals.flatMap { notices.candidates($0.item, plan: $0.previous, now: now) }
        let wanted = proposals.flatMap {
            notices.candidates($0.item, plan: $0.proposal, now: now) + notices.candidates($0.item, plan: $0.previous, now: now)
        }
        let scheduled = allowed ? await notices.stage(wanted, keeping: Set(preserving.map(\.id))) : []
        for item in proposals {
            var updated = item.item
            let desired = notices.candidates(updated, plan: item.proposal, now: now)
            let proposedCoverage = notices.coverage(desired, ids: scheduled, now: now)
            let changed = item.previous != nil && item.previous != item.proposal
            let canReplace = allowed && item.proposal != nil && (!changed || proposedCoverage.complete)
            if canReplace { updated.applied = item.proposal }
            let active = notices.candidates(updated, plan: updated.applied, now: now)
            let actual = notices.coverage(active, ids: scheduled, now: now)
            let keep = allowed ? Set(active.map(\.id)).intersection(scheduled) : []
            try await cloud.requireAccount(account)
            _ = try await merge(updated, base: base)
            await notices.prune(updated.id, keep: keep, entries: updated.entries, now: now)
            let verified = Set(await center.pendingNotificationRequests().map(\.identifier))
            let coverage = notices.coverage(active, ids: verified, now: now)
            if allowed && updated.applied != nil { await notices.promptRenewal(updated.id, coverage: coverage, now: now) }
            if let event = updated.agreement.test, event != updated.scheduledTest, allowed {
                do { try await notices.sendTest(updated.id, event: event); updated.scheduledTest = event } catch {}
            }
            let old = updated.receipt
            let activePlan = updated.applied
            var seen = old?.seen
            if let activePlan, let latest = activePlan.windows(around: now, before: 7).last(where: { updated.entries[$0.id] != nil }) {
                seen = latest.id
            }
            let offered = updated.agreement.plan
            let offeredVersion = offered?.next?.version ?? offered?.current.version
            let appliedVersion = activePlan?.next?.version ?? activePlan?.current.version
            let needsRevision = offeredVersion != appliedVersion || !actual.complete || !coverage.complete
            var ack = WindowReceipt(version: appliedVersion ?? 0, confirmed: now,
                                    coveredUntil: allowed && activePlan != nil ? coverage.until : nil,
                                    allowed: allowed, needsRevision: needsRevision, timeZone: TimeZone.current.identifier,
                                    device: base.device, seen: seen, contacted: old?.contacted, tested: old?.tested,
                                    coverageCount: allowed && activePlan != nil ? coverage.count : 0)
            updated.receipt = ack
            let latest = try await merge(updated, base: base)
            if updated.returnURL != nil {
                let previous = try? await cloud.read(.receiver(updated.id), owned: true).receipt
                if let saved = latest.incoming.first(where: { $0.id == updated.id })?.receipt { ack = saved }
                if shouldPublish(ack, previous: previous, now: now) {
                    let payload = Agreement(pair: updated.id, alias: base.nickname, receipt: ack, linked: updated.agreement.linked)
                    try? await cloud.write(payload, zone: .receiver(updated.id), account: account)
                }
            }
        }
    }

    private func shouldPublish(_ next: WindowReceipt, previous: WindowReceipt?, now: Date) -> Bool {
        guard var previous else { return true }
        if now.timeIntervalSince(previous.confirmed) > 6 * 3600
            || abs((next.coveredUntil ?? .distantPast).timeIntervalSince(previous.coveredUntil ?? .distantPast)) > 3600 {
            return true
        }
        previous.confirmed = next.confirmed
        previous.coveredUntil = next.coveredUntil
        return next != previous
    }

    private func acceptable(_ item: Incoming, now: Date) -> PlanChange? {
        guard let plan = item.agreement.plan else { return nil }
        guard let next = plan.next else {
            if let existing = item.applied, existing.current.version > plan.current.version { return existing }
            return plan
        }
        if item.applied?.next?.version == next.version || (next.effective > now.addingTimeInterval(15 * 60)) {
            return plan
        }
        return item.applied ?? PlanChange(current: plan.current)
    }

    private func merge(_ changed: Incoming, base: CheckInState) async throws -> CheckInState {
        try await update(base) { state in
            guard let index = state.incoming.firstIndex(where: { $0.id == changed.id && !$0.ended }) else { throw LocalError.stale }
            let old = state.incoming[index]
            var item = changed
            item.phone = old.phone
            item.returnURL = old.returnURL ?? item.returnURL
            if old.receipt?.device == item.receipt?.device, var receipt = item.receipt {
                let tested = old.receipt?.tested ?? receipt.tested
                let contacted = old.receipt?.contacted ?? receipt.contacted
                receipt.tested = tested
                receipt.contacted = contacted
                item.receipt = receipt
            }
            state.incoming[index] = item
        }.0
    }
}

private extension CheckInState {
    func validForLink(_ check: CheckIn, link: Outgoing) -> Bool {
        let plans = [link.plan.current] + [link.plan.next].compactMap { $0 }
        return plans.contains { plan in
            plan.version == check.window.version && plan.windows(around: check.window.deadline).contains { $0.id == check.id }
        }
    }
}
