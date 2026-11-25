import SwiftUI
import UIKit

struct ContactsView: View {
    @EnvironmentObject var model: AppModel
    @State private var disconnect: Outgoing?
    @State private var confirming = false
    @State private var busy = false

    var body: some View {
        Screen(title: L.t("contacts.title"), subtitle: L.t("contacts.lead")) {
            if links.isEmpty {
                VStack(alignment: .center, spacing: 12) {
                    EmptyIllustration(symbol: "person.2.fill")
                    Text(L.t("contacts.none")).font(.title3.bold())
                    Footnote(text: L.t("home.selfOnly"))
                    inviteButton
                }.modifier(Surface())
            } else {
                ForEach(model.data.outgoing) { link in contact(link) }
                inviteButton
            }
            if !model.data.revoke.isEmpty { Footnote(text: L.t("contacts.revokePending")) }
            Footnote(text: L.t("contacts.network"))
        }
        .refreshable { await model.refresh() }
        .confirmationDialog(L.t("contacts.disconnect"), isPresented: $confirming, titleVisibility: .visible, presenting: disconnect) { link in
            Button(L.t("contacts.disconnect"), role: .destructive) { Task { _ = await model.disconnect(link.id, incoming: false) } }
        } message: { _ in Text(L.t("contacts.disconnectHint")) }
    }

    private var links: [Outgoing] { model.data.outgoing.filter { !$0.ended } }

    private var inviteButton: some View {
        PrimaryButton(title: L.t("contacts.invite"), symbol: "person.badge.plus", id: "contacts.invite") {
            model.homePath.append(model.data.entitlement.canAddContact(total: links.count, at: model.now) ? .invite : .paywall)
        }
    }

    private func contact(_ link: Outgoing) -> some View {
        let status = link.status(at: model.now)
        let extra = !model.pro && model.data.firstFreeContact != link.id
        return VStack(alignment: .leading, spacing: 9) {
            IconRow(title: link.alias, subtitle: L.t(status), symbol: "person.crop.circle", tone: link.ended ? .neutral : .mint)
            StatusPill(title: L.t(status), symbol: status == "status.tested" ? "checkmark.circle" : "clock",
                       tone: status == "status.tested" ? .mint : .sun)
                .accessibilityIdentifier("contacts.status")
            if let ack = link.ack {
                if let until = ack.coveredUntil {
                    Footnote(text: L.f("contacts.coverage", L.stamp(until)))
                }
                Footnote(text: L.f("contacts.confirmedAt", L.stamp(ack.confirmed)))
                if let reported = ack.contacted,
                   let window = link.plan.windows(around: model.now, before: 7).first(where: { $0.id == reported }) {
                    Footnote(text: L.f("contacts.contacting", L.stamp(window.deadline)))
                }
            }
            if !link.ended {
                if link.returnZone != nil || Launch.testing && link.ack != nil {
                    RouteRow(title: L.t("contacts.test"), subtitle: L.t("contacts.testHint"), symbol: "bell.badge",
                             id: "contacts.test", route: .test(link.id))
                }
                if link.returnZone == nil || link.ack == nil {
                    PrimaryButton(title: L.t("contacts.resend"), symbol: "arrow.up.right", id: "contacts.resend", primary: false) {
                        if extra { model.homePath.append(.paywall) }
                        else { Task { busy = true; _ = await model.resend(link.id); busy = false } }
                    }.disabled(busy)
                }
                if link.ack?.needsRevision == true && link.plan.next != nil {
                    PrimaryButton(title: L.t("contacts.republish"), symbol: "arrow.clockwise", id: "contacts.republish", primary: false) {
                        Task { _ = await model.save(plan: model.data.plan.next ?? model.data.plan.current) }
                    }
                }
                PrimaryButton(title: L.t("contacts.disconnect"), symbol: "link.badge.minus", id: "contacts.disconnect", primary: false, tone: .neutral) {
                    disconnect = link
                    confirming = true
                }
            }
        }.modifier(Surface())
    }
}

struct InviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var alias = ""
    @State private var nickname: String
    @State private var sending = false
    @FocusState private var focused: String?
    init(nickname: String) { _nickname = State(initialValue: nickname) }

    var body: some View {
        Screen(title: L.t("contacts.invite"), subtitle: L.t("contacts.invitationText")) {
            VStack(alignment: .leading, spacing: 12) {
                field("contacts.nickname", text: $nickname, id: "invite.nickname")
                field("contacts.alias", text: $alias, id: "invite.alias")
                field("contacts.address", text: $address, id: "invite.address")
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { focused = nil }
            }.modifier(Surface())
            Footnote(text: L.t("contacts.addressHint"))
            PrimaryButton(title: L.t("contacts.sendInvite"), symbol: "paperplane", id: "invite.send") {
                sending = true
                Task {
                    if await model.invite(address: address, alias: alias, nickname: nickname) { dismiss() }
                    sending = false
                }
            }.disabled(sending || address.isEmpty || alias.isEmpty || nickname.isEmpty)
            if sending { ProgressView() }
        }
    }

    private func field(_ key: String, text: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L.t(key)).font(.subheadline.bold())
            TextField(L.t(key), text: text).textFieldStyle(.roundedBorder)
                .frame(minHeight: 44).accessibilityIdentifier(id).focused($focused, equals: id)
        }
    }
}

struct TestNoticeView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var pair: UUID
    @State private var sending = false

    var body: some View {
        Screen(title: L.t("contacts.test"), subtitle: L.t("contacts.testHint")) {
            HeroCard(symbol: "bell.badge", tone: .sun) {
                Text(model.data.outgoing.first(where: { $0.id == pair })?.alias ?? L.t("contacts.title")).font(.title2.bold())
            }
            PrimaryButton(title: L.t("contacts.sendTest"), symbol: "paperplane", id: "contacts.sendTest") {
                sending = true
                Task {
                    if await model.test(pair) { dismiss() }
                    sending = false
                }
            }.disabled(sending)
        }
    }
}

struct ReceiveView: View {
    @EnvironmentObject var model: AppModel
    @State private var invite = ""
    @State private var opening = false
    var body: some View {
        Screen(title: L.t("receive.title"), subtitle: L.t("receive.lead")) {
            if model.data.incoming.isEmpty {
                VStack(spacing: 12) {
                    EmptyIllustration(symbol: "tray.fill")
                    Text(L.t("receive.empty")).font(.title3.bold())
                    Footnote(text: L.t("receive.openHint"))
                }.modifier(Surface())
            }
            ForEach(model.data.incoming) { item in
                NavigationLink(value: Route.incoming(item.id)) {
                    HeroCard(symbol: "person.crop.circle", tone: item.failed ? .sun : .mint) {
                        StatusPill(title: L.t(status(item)), symbol: item.failed ? "arrow.clockwise" : "tray",
                                   tone: item.failed ? .sun : .mint)
                        Text(item.agreement.alias.isEmpty ? L.t("receive.sender") : item.agreement.alias).font(.title2.bold())
                        Footnote(text: item.lastCheck.map { L.f("receive.last", L.stamp($0.entry.clicked)) } ?? L.t("receive.noCheck"))
                        if let next = item.applied?.windows(around: model.now).first(where: { $0.expiry > model.now }) {
                            Footnote(text: L.f("receive.next", L.stamp(next.expiry)))
                        }
                        if let refreshed = item.refreshed { Footnote(text: L.f("receive.refreshed", L.stamp(refreshed))) }
                    }
                }.buttonStyle(.plain).accessibilityIdentifier("receive.open")
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(L.t("receive.inviteURL"), text: $invite)
                    .textFieldStyle(.roundedBorder).keyboardType(.URL).autocorrectionDisabled()
                    .textInputAutocapitalization(.never).accessibilityIdentifier("receive.url")
                PrimaryButton(title: L.t("receive.openInvite"), symbol: "link", id: "receive.openInvite", primary: false) {
                    guard let url = URL(string: invite.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
                          let host = url.host?.lowercased(), host == "icloud.com" || host.hasSuffix(".icloud.com") else {
                        model.error = "error.link"
                        return
                    }
                    opening = true
                    Task { await model.open(url); opening = false }
                }.disabled(invite.isEmpty || opening)
            }.modifier(Surface())
            PrimaryButton(title: L.t("common.refresh"), symbol: "arrow.clockwise", id: "receive.refresh", primary: false) {
                Task { await model.refresh() }
            }.disabled(model.refreshing)
        }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await model.refresh() }
    }

    private func status(_ item: Incoming) -> String {
        if item.failed { return "receive.unverified" }
        if item.returnURL == nil && !Launch.testing { return "receive.returnNeeded" }
        if item.receipt?.allowed == false { return "notice.disabled" }
        if let window = item.relevant(at: model.now), item.entries[window.id] == nil { return "receive.missed" }
        return "receive.listening"
    }
}

struct ReceiveDetail: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var confirm = false
    @State private var confirmTakeover = false
    @State private var sending = false

    var body: some View {
        if let item = model.data.incoming.first(where: { $0.id == id }) {
            detail(item)
        } else {
            Screen(title: L.t("receive.title")) {
                EmptyIllustration(symbol: "link.badge.minus")
                Footnote(text: L.t("status.ended"))
            }
        }
    }

    private func detail(_ item: Incoming) -> some View {
        let window = selectedWindow(item)
        let event = window.flatMap { item.entries[$0.id] }
        let missed = window.map { $0.expiry <= model.now } == true && event == nil
        let status = reviewStatus(item: item, window: window, event: event, missed: missed)
        let currentDevice = item.ownerDevice == nil || item.ownerDevice == model.data.device
        return Screen(title: item.agreement.alias.isEmpty ? L.t("receive.sender") : item.agreement.alias, subtitle: L.t("receive.detail")) {
            HeroCard(symbol: missed ? "clock.badge.exclamationmark" : "person.crop.circle.badge.checkmark",
                     tone: missed && !item.failed ? .missed : .mint) {
                StatusPill(title: L.t(status), symbol: missed && !item.failed ? "clock.badge.exclamationmark" : "checkmark.circle",
                           tone: missed && !item.failed ? .missed : (item.failed ? .sun : .mint))
                if let window {
                    Text(L.clock(window.expiry)).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Footnote(text: L.f("receive.next", L.stamp(window.expiry)))
                }
            }
            if missed { contactActions(item) }
            VStack(alignment: .leading, spacing: 8) {
                IconRow(title: L.t("receive.latest"), subtitle: item.lastCheck.map {
                    L.stamp($0.entry.clicked)
                } ?? L.t("receive.noCheck"), symbol: "checkmark.circle", tone: .mint)
                if let refreshed = item.refreshed { Footnote(text: L.f("receive.refreshed", L.stamp(refreshed))) }
                if let covered = item.receipt?.coveredUntil {
                    Footnote(text: L.f("contacts.coverage", L.stamp(covered)))
                }
                if !currentDevice { Footnote(text: L.t("receive.otherDevice")) }
                if item.receipt?.needsRevision == true { Footnote(text: L.t("status.waitingNote")) }
                if item.receipt?.allowed == false {
                    Footnote(text: L.t("receive.permission"))
                    PrimaryButton(title: L.t("settings.openDevice"), symbol: "gear", id: "receive.notifications", primary: false) {
                        Task {
                            await model.notices.allow()
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
                PrimaryButton(title: L.t("common.refresh"), symbol: "arrow.clockwise", id: "receive.detailRefresh", primary: false) {
                    Task { await model.refresh() }
                }.disabled(model.refreshing)
            }.modifier(Surface())
            if !currentDevice {
                PrimaryButton(title: L.t("receive.takeover"), symbol: "iphone", id: "receive.takeover") { confirmTakeover = true }.disabled(sending)
            } else if item.returnURL == nil || !Launch.testing {
                PrimaryButton(title: L.t(item.returnURL == nil ? "receive.return" : "receive.returnAgain"),
                              symbol: "arrowshape.turn.up.left", id: "receive.return", primary: item.returnURL == nil) { send() }.disabled(sending)
            }
            if let test = item.agreement.test, item.scheduledTest == test, let receipt = item.receipt,
               receipt.allowed, receipt.tested != test, currentDevice {
                VStack(alignment: .leading, spacing: 8) {
                    IconRow(title: L.t("contacts.test"), subtitle: L.t("receive.testHint"), symbol: "bell", tone: .sun)
                    PrimaryButton(title: L.t("receive.testAck"), symbol: "checkmark", id: "receive.testAck", primary: false) {
                        Task { await model.ack(id, test: true) }
                    }
                }.modifier(Surface())
            }
            if missed, currentDevice {
                PrimaryButton(title: L.t("receive.contactAck"), symbol: "hand.raised", id: "receive.contactAck") {
                    Task { await model.ack(id, test: false, window: window?.id) }
                }.disabled(window?.id == item.receipt?.contacted)
            }
            if !missed { contactActions(item) }
            PrimaryButton(title: L.t("contacts.disconnect"), symbol: "link.badge.minus", id: "receive.disconnect", primary: false, tone: .neutral) {
                confirm = true
            }
        }
        .task { await model.refresh() }
        .onDisappear { model.openedWindow = nil }
        .confirmationDialog(L.t("contacts.disconnect"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.t("contacts.disconnect"), role: .destructive) {
                Task { if await model.disconnect(id, incoming: true) { dismiss() } }
            }
        } message: { Text(L.t("contacts.disconnectHint")) }
        .alert(L.t("receive.takeover"), isPresented: $confirmTakeover) {
            Button(L.t("receive.takeover")) { send(takingOver: true) }
            Button(L.t("common.cancel"), role: .cancel) {}
        } message: { Text(L.t("receive.takeoverHint")) }
    }

    private func send(takingOver: Bool = false) {
        sending = true
        Task {
            await model.returnReceipt(id, takingOver: takingOver)
            sending = false
        }
    }

    private func selectedWindow(_ item: Incoming) -> Window? {
        let windows = item.applied?.windows(around: model.now, before: 7) ?? []
        return windows.first(where: { $0.id == model.openedWindow }) ?? item.relevant(at: model.now)
            ?? windows.first(where: { $0.expiry > model.now })
    }

    private func reviewStatus(item: Incoming, window: Window?, event: CloudCheckIn?, missed: Bool) -> String {
        if item.failed { return "receive.unverified" }
        if let window, let event {
            return Periods.receiverCovers(window, clicked: event.entry.clicked, uploaded: event.uploaded) ? "receive.onTime" : "receive.late"
        }
        if missed, let window {
            return (item.refreshed ?? .distantPast) >= window.expiry ? "receive.missed" : "receive.unverified"
        }
        return item.applied == nil ? "status.waiting" : "receive.listening"
    }

    private func contactActions(_ item: Incoming) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let phone = Phone.clean(item.phone), !phone.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { phoneButtons(phone) }
                    VStack { phoneButtons(phone) }
                }
            } else {
                IconRow(title: L.t("receive.originalContact"), symbol: "bubble.left.and.bubble.right")
            }
            RouteRow(title: L.t("receive.number"), subtitle: L.t("receive.numberHint"),
                     symbol: "phone", id: "receive.number", route: .number(item.id))
        }.modifier(Surface())
    }

    @ViewBuilder private func phoneButtons(_ phone: String) -> some View {
        PrimaryButton(title: L.t("receive.call"), symbol: "phone", id: "receive.call", primary: false) {
            if let url = URL(string: "tel:" + phone) { openURL(url) }
        }
        PrimaryButton(title: L.t("receive.message"), symbol: "message", id: "receive.message", primary: false) {
            if let url = URL(string: "sms:" + phone) { openURL(url) }
        }
    }
}

enum Phone {
    static func clean(_ value: String) -> String? {
        let phone = value.filter { !(" -()".contains($0)) }
        if phone.isEmpty { return "" }
        let digits = phone.hasPrefix("+") ? phone.dropFirst() : phone[...]
        guard (3...20).contains(digits.count), digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return phone
    }
}

struct NumberView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var number: String
    init(id: UUID, number: String) { self.id = id; _number = State(initialValue: number) }

    var body: some View {
        Screen(title: L.t("receive.number"), subtitle: L.t("receive.numberHint")) {
            TextField(L.t("receive.number"), text: $number)
                .textFieldStyle(.roundedBorder).keyboardType(.phonePad).frame(minHeight: 44)
                .accessibilityIdentifier("receive.phoneInput")
            PrimaryButton(title: L.t("common.save"), symbol: "checkmark", id: "receive.numberSave") {
                guard let saved = Phone.clean(number) else { model.error = "error.phone"; return }
                Task {
                    await model.change { state in
                        if let index = state.incoming.firstIndex(where: { $0.id == id }) { state.incoming[index].phone = saved }
                    }
                    dismiss()
                }
            }
        }
    }
}
