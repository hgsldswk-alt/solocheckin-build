import CloudKit
import SwiftUI
import UserNotifications

@main
struct SoloCheckInApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            root
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(Palette.action)
                .task { await model.start() }
                .task(id: phase) {
                    guard phase == .active, !Launch.testing else { return }
                    await model.start()
                    while !Task.isCancelled {
                        await model.refresh()
                        try? await Task.sleep(for: .seconds(35))
                    }
                }
                .onOpenURL { url in Task { await model.open(url) } }
                .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
                    if !Launch.testing { Task { await model.refresh() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    if !Launch.testing { Task { await model.refresh() } }
                }
                .sheet(item: $model.share) { ActivitySheet(payload: $0) }
                .sheet(item: $model.preview) { AcceptView(preview: $0).environmentObject(model) }
                .alert(L.t("common.problem"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                    Button(L.t("common.ok")) { model.error = nil }
                } message: {
                    Text(L.t(model.error ?? "common.problem"))
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if model.sharedForTesting && Launch.testing {
                        banner(L.t("share.ready"), symbol: "square.and.arrow.up")
                            .accessibilityIdentifier("share.requested")
                    } else if let message = model.message {
                        banner(L.t(message), symbol: "info.circle")
                            .accessibilityIdentifier("app.message")
                            .task(id: message) {
                                try? await Task.sleep(for: .seconds(5))
                                if !Task.isCancelled && model.message == message { model.message = nil }
                            }
                    }
                }
        }
    }

    private var root: some View {
        TabView(selection: $model.tab) {
            NavigationStack(path: $model.homePath) { Home().navigationDestination(for: Route.self, destination: destination) }
                .tabItem { Label(L.t("home.tab"), systemImage: "house").accessibilityIdentifier("tab.home") }.tag(0)
            NavigationStack(path: $model.receivePath) { ReceiveView().navigationDestination(for: Route.self, destination: destination) }
                .tabItem { Label(L.t("receive.title"), systemImage: "tray").accessibilityIdentifier("tab.receive") }.tag(1)
            NavigationStack(path: $model.settingsPath) { Settings().navigationDestination(for: Route.self, destination: destination) }
                .tabItem { Label(L.t("settings.title"), systemImage: "gearshape").accessibilityIdentifier("tab.settings") }.tag(2)
        }
        .toolbarBackground(Palette.paper, for: .tabBar)
    }

    private func destination(_ route: Route) -> some View {
        content(route).toolbar(.visible, for: .navigationBar)
    }

    @ViewBuilder private func content(_ route: Route) -> some View {
        switch route {
        case .time: TimeView(rule: model.rule)
        case .contacts: ContactsView()
        case .travel: TravelView(now: model.now)
        case .pause: PauseView(now: model.now)
        case .invite: InviteView(nickname: model.data.nickname)
        case .test(let pair): TestNoticeView(pair: pair)
        case .incoming(let id): ReceiveDetail(id: id)
        case .number(let id):
            NumberView(id: id, number: model.data.incoming.first(where: { $0.id == id })?.phone ?? "")
        case .history: HistoryView()
        case .share(let count): ShareScreen(milestone: count)
        case .codes: CodesScreen()
        case .paywall: PaywallView(purchases: model.purchases)
        case .privacy: PrivacyView()
        }
    }

    private func banner(_ value: String, symbol: String) -> some View {
        Label(value, systemImage: symbol).font(.footnote.weight(.semibold)).foregroundStyle(Palette.action)
            .padding(8).frame(maxWidth: .infinity).background(Palette.sky)
            .accessibilityElement(children: .ignore).accessibilityLabel(value)
    }
}

struct AcceptView: View {
    let preview: SharePreview
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var accepting = false

    var body: some View {
        Screen(title: L.t(preview.isReturn ? "receive.acceptReturn" : "receive.acceptInvite")) {
            HeroCard(symbol: preview.isReturn ? "checkmark.seal" : "person.2.fill") {
                if !preview.title.isEmpty { Text(preview.title).font(.title2.bold()) }
                Footnote(text: L.t(preview.isReturn ? "receive.acceptReturnHint" : "receive.acceptInviteHint"))
            }
            PrimaryButton(title: L.t(preview.isReturn ? "receive.acceptReturn" : "receive.accept"),
                          symbol: "checkmark", id: "receive.accept") {
                accepting = true
                Task { _ = await model.accept(preview); accepting = false }
            }.disabled(accepting)
            if accepting { ProgressView() }
            PrimaryButton(title: L.t("common.cancel"), symbol: "xmark", id: "receive.cancel", primary: false) { dismiss() }
                .disabled(accepting)
        }
        .alert(L.t("common.problem"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(L.t("common.ok")) { model.error = nil }
        } message: { Text(L.t(model.error ?? "common.problem")) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !Launch.testing {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = session.configuration
        configuration.delegateClass = CloudSceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await AppModel.shared.show(metadata) }
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completion: @escaping (UIBackgroundFetchResult) -> Void) {
        guard !Launch.testing, CKNotification(fromRemoteNotificationDictionary: userInfo)?.subscriptionID == "solo-shared-v1"
        else { completion(.noData); return }
        Task { @MainActor in
            let model = AppModel.shared
            await model.start()
            await model.refresh()
            completion(.newData)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.identifier
        let info = notification.request.content.userInfo
        let state = try? await LocalStore.read()
        if id.hasPrefix(Notice.personal), let window = info["window"] as? String, state?.checks[window] != nil { return [] }
        if id.hasPrefix(Notice.receiver), let pair = (info["pair"] as? String).flatMap(UUID.init(uuidString:)),
           let window = info["window"] as? String {
            Task { await AppModel.shared.refresh() }
            if state?.incoming.first(where: { $0.id == pair })?.entries[window] != nil { return [] }
        }
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == Notice.checkAction else { return }
        await AppModel.shared.openNotice(response.notification.request.content.userInfo,
                                         isAction: response.actionIdentifier == Notice.checkAction)
    }
}

final class CloudSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        if let metadata = options.cloudKitShareMetadata {
            Task { await AppModel.shared.show(metadata) }
        }
        for context in options.urlContexts {
            Task { await AppModel.shared.open(context.url) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await AppModel.shared.show(metadata) }
    }
}
