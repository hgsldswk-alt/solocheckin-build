import StoreKit
import SwiftUI

struct Home: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.requestReview) private var requestReview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var ringSize = 75.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            contents(at: model.now)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: model.reviewCandidate) {
            guard model.reviewCandidate else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if await model.mayReview(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1") {
                requestReview()
            }
        }
    }

    @ViewBuilder private func contents(at now: Date) -> some View {
        let state = model.data
        let check = state.checkIn(at: now)
        let window = state.activeWindow(at: now)
        let forced = Launch.testing && Launch.arguments.contains("-reminder")
        let due = check == nil && (forced || (window.map { $0.version > 0 && $0.deadline <= now && now <= $0.expiry } ?? false))
        let next = state.enabled ? state.plan.windows(around: now).first {
            $0.deadline > now && !state.hasChecked($0, at: now)
        } : nil
        let contacts = state.outgoing.filter { !$0.ended }
        Screen(title: L.t("app.name"), subtitle: now.formatted(.dateTime.month(.wide).day().weekday(.wide))) {
            if due, let window {
                reminder(window, now: now, forced: forced)
            } else {
                HeroCard(symbol: check == nil ? "house.lodge" : "house.fill", tone: check == nil ? .sky : .mint) {
                    StatusPill(title: L.t(check == nil ? "home.pending" : "home.done"),
                               symbol: check == nil ? "sun.max" : "checkmark.circle", tone: check == nil ? .sky : .mint)
                    Text(L.t(check == nil ? "home.title" : "home.doneTitle")).font(.title2.bold())
                    Footnote(text: L.t(check == nil ? "home.hint" : "home.doneHint"))
                }
            }
            VStack(spacing: 8) {
                PrimaryButton(title: check.map { L.f("home.doneAt", L.clock($0.clicked)) } ?? L.t("home.check"),
                              symbol: "checkmark.circle", id: "home.check", primary: check == nil,
                              tone: check == nil ? .sky : .mint) {
                    Task { await model.check() }
                }.disabled(!model.ready || model.checking)
                if let check {
                    Text(syncText(check, contacts: contacts)).font(.footnote).foregroundStyle(Palette.muted)
                        .accessibilityIdentifier("home.sync")
                    if check.window.timing(at: check.clicked) == .overdue { Footnote(text: L.t("home.late")) }
                } else if let window, window.isTrip || window.opens < model.rule.calendar.startOfDay(for: now) {
                    Footnote(text: L.f("home.appliesTo", L.stamp(window.deadline, zone: model.rule.zone)))
                } else if let next {
                    Footnote(text: L.f("home.remindAt", L.clock(next.deadline, zone: model.rule.zone)))
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: check?.id)
            if let late = state.lateWindow(at: now) {
                PrimaryButton(title: L.f("home.completeLate", L.stamp(late.deadline)), symbol: "clock.arrow.circlepath",
                              id: "home.completeLate", primary: false, tone: .sun) {
                    Task { await model.check(late: late) }
                }.disabled(model.checking)
            }
            let nextLine = next.map { L.stamp($0.deadline, zone: model.rule.zone) } ?? L.t(state.enabled ? "home.noUpcoming" : "home.setTime")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 9) { tiles(time: nextLine, contacts: contacts, now: now) }
                VStack(spacing: 9) { tiles(time: nextLine, contacts: contacts, now: now) }
            }
            VStack(alignment: .leading, spacing: 9) {
                IconRow(title: L.t("notice.mode"), subtitle: L.t(model.capability), symbol: "bell.badge", tone: .sun)
                if contacts.isEmpty { Footnote(text: L.t("home.selfOnly")) }
                if let next {
                    ForEach(contacts) { contact in
                        if let id = contact.ack?.timeZone, let zone = TimeZone(identifier: id) {
                            Footnote(text: L.f("plan.partnerTime", contact.alias, L.stamp(next.expiry, zone: zone), L.zone(zone, at: next.expiry)))
                        }
                    }
                }
                if state.clockWarning {
                    Footnote(text: L.t("clock.warning"))
                    PrimaryButton(title: L.t("clock.confirm"), symbol: "clock.arrow.circlepath", id: "home.confirmClock", primary: false) {
                        Task {
                            await model.change { $0.clockWarning = false }
                            await model.refresh()
                        }
                    }
                }
            }.modifier(Surface())
        }
    }

    private func reminder(_ window: Window, now: Date, forced: Bool) -> some View {
        let remaining = forced ? 28 : max(0, Int(ceil(window.expiry.timeIntervalSince(now) / 60)))
        return HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 7) {
                StatusPill(title: L.t("notice.mode"), symbol: "bell", tone: .sun)
                Text(L.t("notice.due")).font(.title2.bold())
                Footnote(text: L.f("home.reminderDetail", L.clock(window.expiry, zone: model.rule.zone)))
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(Tone.sun.fill, lineWidth: 6)
                Circle().trim(from: 0, to: min(1, Double(remaining) * 60 / max(1, window.expiry.timeIntervalSince(window.deadline))))
                    .stroke(Palette.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round)).rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text(remaining.formatted()).font(.system(.title, design: .rounded, weight: .bold))
                    Text(L.t("plan.minuteUnit")).font(.caption2)
                }
            }
            .frame(width: ringSize, height: ringSize)
            .accessibilityLabel(L.f("notice.grace", remaining))
        }.modifier(Surface(fill: Tone.sun.fill.opacity(0.35)))
        .accessibilityElement(children: .contain).accessibilityIdentifier("home.reminder")
    }

    @ViewBuilder private func tiles(time: String, contacts: [Outgoing], now: Date) -> some View {
        NavigationLink(value: Route.time) {
            IconTile(title: L.t("plan.title"), subtitle: time, symbol: "clock", tone: .sun)
        }.buttonStyle(.plain).accessibilityIdentifier("home.time")
        NavigationLink(value: Route.contacts) {
            IconTile(title: L.t("contacts.title"), subtitle: contacts.first.map {
                "\($0.alias) · \(L.t($0.status(at: now)))"
            } ?? L.t("contacts.none"), symbol: "person.2", tone: .mint)
        }.buttonStyle(.plain).accessibilityIdentifier("home.contacts")
    }

    private func syncText(_ check: CheckIn, contacts: [Outgoing]) -> String {
        guard !contacts.isEmpty else { return L.t("home.local") }
        let relevant = model.data.checks.values.filter { $0.clicked == check.clicked }
        let matches: [(check: CheckIn, uploaded: Date, peer: Bool)] = contacts.compactMap { link in
            relevant.first(where: { $0.id == link.ack?.seen && link.uploaded[$0.id] != nil })
                .flatMap { entry in link.uploaded[entry.id].map { (entry, $0, true) } }
                ?? relevant.first(where: { link.uploaded[$0.id] != nil })
                .flatMap { entry in link.uploaded[entry.id].map { (entry, $0, false) } }
        }
        if matches.count == contacts.count {
            if matches.contains(where: { $0.uploaded > $0.check.window.expiry }) { return L.t("home.lateSynced") }
            if matches.allSatisfy({ $0.peer }) { return L.t("home.peerSynced") }
            return L.t("home.synced")
        }
        if !matches.isEmpty { return L.t("home.partial") }
        return L.t("home.pendingSync")
    }
}
