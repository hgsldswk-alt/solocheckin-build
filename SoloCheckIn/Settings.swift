import StoreKit
import SwiftUI
import UIKit

struct Settings: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @State private var clear = false
    var body: some View {
        Screen(title: L.t("settings.title")) {
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    IconRow(title: L.t("settings.notifications"), subtitle: L.t(model.capability),
                            symbol: "bell", tone: .sun, arrow: true)
                }.buttonStyle(.plain).accessibilityIdentifier("settings.notifications")
                if StrongAlarm.supported {
                    Divider()
                    PrimaryButton(title: L.t(model.data.alarmWanted ? "notice.disableAlarm" : "notice.enableAlarm"),
                                  symbol: "alarm", id: "settings.alarm", primary: false) {
                        Task { await model.enableAlarm() }
                    }
                }
                Divider()
                Button {
                    model.tab = 0
                    model.homePath = [.time]
                } label: {
                    IconRow(title: L.t("settings.own"), symbol: "clock", tone: .sun, arrow: true)
                }.buttonStyle(.plain).accessibilityIdentifier("settings.own")
            }.modifier(Surface())
            VStack(alignment: .leading, spacing: 5) {
                RouteRow(title: L.t("history.title"), symbol: "calendar", id: "settings.history", route: .history, tone: .mint)
                Divider()
                RouteRow(title: L.t("share.title"), symbol: "square.and.arrow.up", id: "settings.share", route: .share(nil))
                Divider()
                RouteRow(title: L.t("code.title"), symbol: "doc.on.clipboard", id: "settings.codes", route: .codes)
                if !Launch.testing {
                    PasteButton(payloadType: String.self) { values in
                        if let value = values.first { previewCode(value) }
                    }
                    .buttonBorderShape(.capsule)
                    .frame(minHeight: 44)
                    .accessibilityLabel(L.t("code.paste"))
                    .accessibilityIdentifier("settings.paste")
                } else if let value = ProcessInfo.processInfo.environment["SOLO_TEST_CODE"] {
                    PrimaryButton(title: L.t("code.paste"), symbol: "doc.on.clipboard", id: "settings.paste", primary: false) {
                        previewCode(value)
                    }
                }
            }.modifier(Surface())
            if !Launch.isFree {
                RouteRow(title: L.t("purchase.title"), subtitle: L.t(model.pro ? "purchase.active" : "purchase.free"),
                         symbol: "sparkles", id: "settings.paywall", route: .paywall, tone: .sun).modifier(Surface())
            }
            VStack(alignment: .leading, spacing: 5) {
                RouteRow(title: L.t("settings.privacy"), symbol: "lock", id: "settings.privacy", route: .privacy)
                Divider()
                Button { clear = true } label: {
                    IconRow(title: L.t("settings.clear"), symbol: "trash", tone: .neutral, arrow: true)
                }.buttonStyle(.plain).accessibilityIdentifier("settings.clear")
            }.modifier(Surface())
            if !model.data.revoke.isEmpty { Footnote(text: L.t("contacts.revokePending")) }
        }
        .toolbar(.hidden, for: .navigationBar)
        .alert(L.t("settings.clear"), isPresented: $clear) {
            Button(L.t("common.cancel"), role: .cancel) {}
            Button(L.t("settings.clearConfirm"), role: .destructive) { Task { await model.clear() } }
        } message: { Text(L.t("settings.clearDetail")) }
    }

    private func previewCode(_ value: String) {
        model.pendingCodeText = value
        model.settingsPath.append(.codes)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var days = 90
    @State private var exporting = false
    var body: some View {
        Screen(title: L.t("history.title"), subtitle: L.f("history.total", model.data.distinctDays.count)) {
            let milestones = [7, 30].filter { model.data.distinctDays.count >= $0 && !model.data.seenMilestones.contains($0) }
            ForEach(milestones, id: \.self) { count in
                PrimaryButton(title: L.f("share.milestoneTitle", count), symbol: "sun.max", id: "milestone.\(count)", primary: false, tone: .mint) {
                    Task {
                        await model.change { $0.seenMilestones.insert(count) }
                        model.settingsPath.append(.share(count))
                    }
                }
            }
            if model.pro {
                Picker(L.t("history.filter"), selection: $days) {
                    ForEach([7, 30, 90], id: \.self) { Text(L.f("history.days", $0)).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("history.filter")
            }
            if entries.isEmpty {
                VStack(spacing: 8) {
                    EmptyIllustration(symbol: "calendar")
                    Footnote(text: L.t("history.empty"))
                    PrimaryButton(title: L.t("home.tab"), symbol: "house", id: "history.home", primary: false) {
                        model.tab = 0
                        model.homePath = []
                    }
                }.modifier(Surface())
            }
            LazyVStack(spacing: 9) {
                ForEach(entries) { check in
                    IconRow(title: L.stamp(check.clicked),
                            subtitle: L.t(check.window.timing(at: check.clicked) == .overdue ? "home.late" : "home.done"),
                            symbol: "checkmark.circle", tone: .mint)
                    .modifier(Surface())
                    .accessibilityElement(children: .combine).accessibilityIdentifier("history.entry")
                }
            }
            PrimaryButton(title: L.t("history.export"), symbol: "square.and.arrow.up", id: "history.export", primary: false) {
                if !model.pro { model.settingsPath.append(.paywall) }
                else { export() }
            }.disabled(exporting || (model.pro && entries.isEmpty))
        }
    }

    private var entries: [CheckIn] {
        let cutoff = model.now.addingTimeInterval(-Double(model.pro ? days : 90) * 86_400)
        return model.data.history.filter { $0.clicked >= cutoff }
    }

    private func export() {
        let history = entries
        exporting = true
        Task {
            do {
                let file = try await Task.detached {
                    let formatter = ISO8601DateFormatter()
                    let header = [L.t("history.exportTime"), L.t("history.exportDeadline"), L.t("history.exportResult")].joined(separator: ",")
                    let lines = history.map {
                        [formatter.string(from: $0.clicked), formatter.string(from: $0.window.deadline),
                         L.t($0.window.timing(at: $0.clicked) == .overdue ? "home.late" : "home.done")].joined(separator: ",")
                    }
                    return try await ExportFile.write(([header] + lines).joined(separator: "\r\n") + "\r\n", extension: "csv")
                }.value
                model.requestShare([file])
            } catch { model.error = "error.share" }
            exporting = false
        }
    }
}

struct PaywallView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var purchases: Purchases

    var body: some View {
        Screen(title: L.t("purchase.title")) {
            HeroCard(symbol: "heart.circle", tone: .sun) {
                StatusPill(title: L.t("purchase.once"), symbol: "checkmark.seal", tone: .sun)
                Text(L.t("purchase.lead")).font(.title2.bold())
                Footnote(text: L.t("purchase.noCharge"))
            }
            VStack(alignment: .leading, spacing: 4) {
                IconRow(title: L.t("purchase.contacts"), symbol: "person.3", tone: .mint)
                Divider()
                IconRow(title: L.t("purchase.trips"), symbol: "figure.hiking")
                Divider()
                IconRow(title: L.t("purchase.history"), symbol: "calendar", tone: .sun)
            }.modifier(Surface())
            VStack(alignment: .leading, spacing: 6) {
                if model.data.entitlement.purchasedPro { Footnote(text: L.t("purchase.owned")) }
                else if model.pro { Footnote(text: L.f("purchase.until", L.stamp(model.data.entitlement.trialEnd))) }
                else { Footnote(text: L.t("purchase.expired")) }
                Footnote(text: L.t("purchase.freeDetail"))
            }
            if !model.data.entitlement.purchasedPro {
                PrimaryButton(title: buyTitle, symbol: "checkmark.seal", id: "purchase.buy") {
                    Task { await purchases.buy(purchases.pro) }
                }.disabled(!Launch.testing && (purchases.pro == nil || purchases.busy))
                if model.data.entitlement.trialClaimedAt == nil && model.pro {
                    PrimaryButton(title: L.t("purchase.claim"), symbol: "clock", id: "purchase.claim", primary: false) {
                        Task { await purchases.buy(purchases.trial) }
                    }.disabled(!Launch.testing && (purchases.trial == nil || purchases.busy))
                }
            }
            PrimaryButton(title: L.t("purchase.restore"), symbol: "arrow.clockwise", id: "purchase.restore", primary: false) {
                Task { await purchases.restore() }
            }.disabled(purchases.busy)
            if purchases.busy { ProgressView() }
            if let message = purchases.message { Footnote(text: L.t(message)) }
        }.task { await purchases.load() }
    }

    private var buyTitle: String {
        if Launch.testing { return L.f("purchase.buy", "US$4.99") }
        return purchases.pro.map { L.f("purchase.buy", $0.displayPrice) } ?? L.t("purchase.priceUnavailable")
    }
}

struct PrivacyView: View {
    var body: some View {
        Screen(title: L.t("settings.privacy")) {
            VStack(alignment: .leading, spacing: 12) {
                IconRow(title: L.t("privacy.local"), subtitle: L.t("privacy.localBody"), symbol: "iphone")
                Divider()
                IconRow(title: L.t("privacy.cloud"), subtitle: L.t("privacy.cloudBody"), symbol: "lock.icloud", tone: .mint)
                Divider()
                IconRow(title: L.t("privacy.delivery"), subtitle: L.t("contacts.network"), symbol: "bell", tone: .sun)
                Divider()
                IconRow(title: L.t("settings.clear"), subtitle: L.t("settings.clearDetail"), symbol: "trash")
            }.modifier(Surface())
            Footnote(text: L.t("privacy.widget"))
        }
    }
}
