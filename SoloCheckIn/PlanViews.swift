import SwiftUI

struct TimeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rule: DailyRule
    @State private var confirm = false
    @State private var saving = false
    @ScaledMetric private var ring = 78.0

    init(rule: DailyRule) { _rule = State(initialValue: rule) }

    var body: some View {
        Screen(title: L.t("plan.title"), subtitle: L.t("plan.lead")) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t("plan.daily")).font(.headline)
                    DatePicker(L.t("plan.daily"), selection: timeBinding, displayedComponents: .hourAndMinute)
                        .labelsHidden().environment(\.timeZone, rule.zone)
                        .accessibilityIdentifier("plan.time")
                    Footnote(text: L.zone(rule.zone, at: model.now))
                }
                Spacer(minLength: 0)
                VStack(spacing: 0) {
                    Text(rule.grace.formatted()).font(.system(.title, design: .rounded, weight: .bold))
                    Text(L.t("plan.minuteUnit")).font(.caption2)
                }
                .frame(width: ring, height: ring)
                .background(Tone.sun.fill, in: Circle())
                .overlay(Circle().trim(from: 0, to: Double(rule.grace) / 120).stroke(Palette.orange, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90)))
                .foregroundStyle(Tone.sun.ink)
                .accessibilityHidden(true)
            }.modifier(Surface(fill: Tone.sky.fill))
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t("plan.grace")).font(.headline)
                Footnote(text: L.t("plan.graceHint"))
                GracePicker(grace: $rule.grace)
            }.modifier(Surface())
            VStack(alignment: .leading, spacing: 8) {
                Picker(selection: $rule.zoneID) {
                    ForEach(zoneIDs, id: \.self) { id in
                        if let zone = TimeZone(identifier: id) { Text(L.zone(zone, at: model.now) + " · " + id).tag(id) }
                    }
                } label: {
                    Label(L.t("plan.zone"), systemImage: "globe")
                }
                .pickerStyle(.navigationLink)
                .accessibilityIdentifier("plan.zone")
                LocalTimes(date: previewExpiry, zone: rule.zone)
                if model.data.plan.next != nil && model.data.outgoing.contains(where: {
                    !$0.ended && $0.ack?.version != ($0.plan.next?.version ?? $0.plan.current.version)
                }) {
                    Footnote(text: L.t("status.waitingNote"))
                }
            }.modifier(Surface())
            VStack(alignment: .leading, spacing: 4) {
                RouteRow(title: L.t("trip.title"), subtitle: L.t("trip.short"), symbol: "figure.hiking", id: "plan.travel", route: .travel, tone: .mint)
                Divider()
                RouteRow(title: L.t("pause.title"), subtitle: pauseLine, symbol: "pause.circle", id: "plan.pause", route: .pause, tone: .sun)
            }.modifier(Surface())
            PrimaryButton(title: L.t("common.save"), symbol: "checkmark", id: "plan.save") {
                if model.data.outgoing.contains(where: { !$0.ended }) { confirm = true } else { save() }
            }.disabled(saving)
        }
        .task { await model.notices.allow(); await model.refresh() }
        .confirmationDialog(L.t("plan.confirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.t("common.save")) { save() }
        } message: { Text(L.t("status.waitingNote")) }
    }

    private var zoneIDs: [String] { Array(Set(TimeZone.knownTimeZoneIdentifiers + [rule.zoneID])).sorted() }

    private var pauseLine: String {
        if let until = (model.data.plan.next ?? model.data.plan.current).pausedUntil, until > model.now {
            return L.f("pause.until", L.stamp(until, zone: rule.zone))
        }
        return L.t("pause.short")
    }

    private var previewExpiry: Date {
        let now = model.now
        let today = rule.deadline(on: now)
        let deadline = today.flatMap { $0 > now ? $0 : nil } ?? rule.deadline(on: rule.followingDay(after: now)) ?? now
        return deadline.addingTimeInterval(Double(rule.grace) * 60)
    }

    private var timeBinding: Binding<Date> {
        Binding(get: {
            rule.calendar.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: rule.hour, minute: rule.minute)) ?? model.now
        }, set: { date in
            let components = rule.calendar.dateComponents([.hour, .minute], from: date)
            rule.hour = components.hour ?? 21
            rule.minute = components.minute ?? 0
        })
    }

    private func save() {
        guard !saving else { return }
        saving = true
        var plan = model.data.plan.next ?? model.data.plan.current
        plan.rule = rule
        Task {
            if await model.save(plan: plan) { dismiss() }
            saving = false
        }
    }
}

struct LocalTimes: View {
    @EnvironmentObject var model: AppModel
    let date: Date
    let zone: TimeZone
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            IconRow(title: L.t("plan.bothTimes"), subtitle: L.f("plan.yourTime", L.stamp(date, zone: .current),
                                                              L.zone(.current, at: date)), symbol: "clock.arrow.2.circlepath")
            if zone.identifier != TimeZone.current.identifier {
                Footnote(text: L.f("plan.agreementTime", L.stamp(date, zone: zone), L.zone(zone, at: date)))
            }
            ForEach(model.data.outgoing.filter { !$0.ended }) { item in
                if let id = item.ack?.timeZone, let theirZone = TimeZone(identifier: id) {
                    Footnote(text: L.f("plan.partnerTime", item.alias, L.stamp(date, zone: theirZone), L.zone(theirZone, at: date)))
                }
            }
        }
    }
}

struct TravelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var starts: Date
    @State private var returns: Date
    @State private var grace = 30
    @State private var confirm = false
    @State private var removal: Trip?
    @State private var saving = false

    init(now: Date) {
        _starts = State(initialValue: now.addingTimeInterval(86_400))
        _returns = State(initialValue: now.addingTimeInterval(90_000))
    }

    var body: some View {
        Screen(title: L.t("trip.title"), subtitle: L.t("trip.lead")) {
            if let first = trips.first {
                IconRow(title: L.stamp(first.returns, zone: model.rule.zone), subtitle: tripState(for: first),
                        symbol: "checkmark.circle", tone: .mint)
                    .modifier(Surface())
            }
            VStack(alignment: .leading, spacing: 10) {
                IconRow(title: L.t("trip.window"), subtitle: L.zone(model.rule.zone, at: returns), symbol: "figure.hiking", tone: .mint)
                DatePicker(L.t("trip.starts"), selection: $starts).accessibilityIdentifier("trip.starts")
                DatePicker(L.t("trip.returns"), selection: $returns).accessibilityIdentifier("trip.returns")
                Text(L.t("plan.grace")).font(.headline)
                GracePicker(grace: $grace, id: "trip.grace")
                LocalTimes(date: returns.addingTimeInterval(Double(grace) * 60), zone: model.rule.zone)
            }
            .environment(\.timeZone, model.rule.zone)
            .modifier(Surface(fill: Tone.sky.fill))
            Footnote(text: L.t("trip.wait"))
            PrimaryButton(title: L.t("common.save"), symbol: "checkmark", id: "trip.save") {
                removal = nil
                if !canAdd { model.homePath.append(.paywall) }
                else if hasContacts { confirm = true }
                else { save() }
            }.disabled(saving)
            if !trips.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L.t("trip.saved")).font(.headline)
                    ForEach(trips) { trip in
                        IconRow(title: L.stamp(trip.returns, zone: model.rule.zone), subtitle: tripState(for: trip),
                                symbol: "figure.hiking", tone: .mint)
                        PrimaryButton(title: L.t("trip.remove"), symbol: "xmark", id: "trip.remove.\(trip.id.uuidString)", primary: false) {
                            removal = trip
                            confirm = true
                        }.disabled(saving)
                        if trip.id != trips.last?.id { Divider() }
                    }
                }.modifier(Surface())
            }
        }
        .confirmationDialog(L.t("plan.confirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.t("common.save")) { save(removing: removal); removal = nil }
        } message: { Text(L.t("status.waitingNote")) }
    }

    private var hasContacts: Bool { model.data.outgoing.contains { !$0.ended } }
    private var trips: [Trip] { (model.data.plan.next ?? model.data.plan.current).trips.filter { $0.expiry > model.now } }
    private var canAdd: Bool { model.data.entitlement.canAddTrip(total: trips.count, at: model.now) }
    private func tripState(for trip: Trip) -> String {
        let checked = model.data.outgoing.filter { !$0.ended }
        guard !checked.isEmpty else { return L.t("status.saved") }
        if checked.allSatisfy({ link in
            guard let ack = link.ack else { return false }
            return ack.version == (link.plan.next?.version ?? link.plan.current.version)
                && ack.allowed && !ack.needsRevision && (ack.coveredUntil ?? .distantPast) >= trip.expiry
                && model.now.timeIntervalSince(ack.confirmed) < 48 * 3600
        }) {
            return L.t("trip.confirmed")
        }
        return L.t("status.waiting")
    }

    private func save(removing: Trip? = nil) {
        guard !saving else { return }
        var plan = model.data.plan.next ?? model.data.plan.current
        plan.trips = trips
        if let removing {
            plan.trips.removeAll { $0.id == removing.id }
        } else {
            let roundedNow = Date(timeIntervalSince1970: floor(model.now.timeIntervalSince1970 / 60) * 60)
            let earliest = hasContacts ? model.rule.followingDay(after: model.now) : roundedNow
            let trip = Trip(starts: starts, returns: returns, grace: grace)
            guard starts >= earliest, trip.valid, returns > model.now else { model.error = "error.trip"; return }
            plan.trips.append(trip)
        }
        saving = true
        Task {
            if await model.save(plan: plan) { dismiss() }
            saving = false
        }
    }
}

struct PauseView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var until: Date
    @State private var confirm = false
    @State private var resume = false
    @State private var saving = false
    init(now: Date) { _until = State(initialValue: now.addingTimeInterval(2 * 86_400)) }

    var body: some View {
        Screen(title: L.t("pause.title"), subtitle: L.t("pause.short")) {
            DatePicker(L.t("pause.date"), selection: $until)
                .environment(\.timeZone, model.rule.zone).modifier(Surface())
                .accessibilityIdentifier("pause.until")
            if let saved = (model.data.plan.next ?? model.data.plan.current).pausedUntil, saved > model.now {
                Footnote(text: L.f("pause.until", L.stamp(saved, zone: model.rule.zone)))
                PrimaryButton(title: L.t("pause.resume"), symbol: "play", id: "pause.resume", primary: false) { submit(resume: true) }
                    .disabled(saving)
            }
            Footnote(text: L.t("status.waitingNote"))
            PrimaryButton(title: L.t("common.save"), symbol: "checkmark", id: "pause.save") { submit(resume: false) }
                .disabled(saving)
        }
        .confirmationDialog(L.t("plan.confirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.t("common.save")) { save() }
        } message: { Text(L.t("status.waitingNote")) }
    }

    private func submit(resume: Bool) {
        self.resume = resume
        if model.data.outgoing.contains(where: { !$0.ended }) { confirm = true } else { save() }
    }

    private func save() {
        guard !saving else { return }
        let start = model.data.outgoing.contains(where: { !$0.ended }) ? model.rule.followingDay(after: model.now) : model.now
        guard resume || until > start else { model.error = "error.pause"; return }
        var plan = model.data.plan.next ?? model.data.plan.current
        plan.pausedFrom = resume ? nil : start
        plan.pausedUntil = resume ? nil : until
        saving = true
        Task {
            if await model.save(plan: plan) { dismiss() }
            saving = false
        }
    }
}
