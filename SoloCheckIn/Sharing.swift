import CoreImage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SharePayload: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct ActivitySheet: UIViewControllerRepresentable {
    let payload: SharePayload
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: payload.items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum ShareCard {
    static var storeURL: URL? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "APP_STORE_ID") as? String, !id.isEmpty,
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return URL(string: "https://apps.apple.com/app/id" + id)
    }

    @MainActor static func export(milestone: Int?, topics: Bool, qr: CGImage?) -> UIImage? {
        let renderer = ImageRenderer(content: ShareArtwork(milestone: milestone, topics: topics, qr: qr)
            .environment(\.colorScheme, .light).environment(\.dynamicTypeSize, .medium))
        renderer.scale = 3
        return renderer.uiImage
    }
}

struct ShareArtwork: View {
    var milestone: Int?
    var topics: Bool
    var qr: CGImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L.t("app.name")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Image(systemName: "sun.max.fill").foregroundStyle(Palette.orange).accessibilityHidden(true)
            }.foregroundStyle(Palette.action)
            ZStack {
                Circle().fill(Tone.sky.fill).frame(width: 136, height: 136)
                Circle().fill(Tone.sun.fill).frame(width: 50, height: 50).offset(x: 53, y: -42)
                Image(systemName: "house.fill").font(.system(size: 66, weight: .medium))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(Palette.action)
                Glyph(name: "checkmark", tone: .mint, size: 42).offset(x: 50, y: 42)
            }.frame(maxWidth: .infinity).accessibilityHidden(true)
            Text(milestone.map { L.f("share.milestoneTitle", $0) } ?? L.t("share.cardTitle"))
                .font(.system(size: 26, weight: .bold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            Text(L.t("share.subtitle")).font(.system(size: 15)).foregroundStyle(Palette.muted)
            Spacer(minLength: 0)
            HStack(spacing: 11) {
                if let qr {
                    Image(decorative: qr, scale: 1).interpolation(.none).resizable().scaledToFit()
                        .padding(7).frame(width: 76, height: 76).background(.white)
                        .accessibilityLabel(L.t("share.scan"))
                } else {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 26, weight: .light))
                        .foregroundStyle(Palette.action).frame(width: 60, height: 60)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.t(qr == nil ? "share.placeholder" : "share.scan")).font(.system(size: 12, weight: .semibold))
                    if topics { Text(L.t("share.topics")).font(.system(size: 11)).foregroundStyle(Palette.action) }
                }
            }
        }
        .padding(28).frame(width: 360, height: 450)
        .background(LinearGradient(colors: [Palette.sky, .white, Tone.sun.fill], startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(
            LinearGradient(colors: [Palette.blue, Palette.mint, Palette.orange], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 3))
        .background(Palette.paper)
        .foregroundStyle(Palette.ink)
    }
}

struct ShareScreen: View {
    @EnvironmentObject var model: AppModel
    var milestone: Int?
    @State private var topics = false
    @State private var qr: CGImage?
    var body: some View {
        Screen(title: L.t("share.title"), subtitle: L.t("share.privacy")) {
            GeometryReader { proxy in
                let scale = min(1, proxy.size.width / 360)
                ShareArtwork(milestone: milestone, topics: topics, qr: qr)
                    .scaleEffect(scale, anchor: .topLeading)
            }.aspectRatio(4.0 / 5.0, contentMode: .fit).frame(maxWidth: 360)
            Toggle(L.t("share.includeTopics"), isOn: $topics).frame(minHeight: 44)
                .accessibilityIdentifier("share.topics")
            PrimaryButton(title: L.t("share.send"), symbol: "square.and.arrow.up", id: "share.send") {
                guard let image = ShareCard.export(milestone: milestone, topics: topics, qr: qr) else {
                    model.error = "error.share"
                    return
                }
                var items: [Any] = [image]
                if topics { items.append(L.t("share.topics")) }
                model.requestShare(items)
            }
        }
        .task {
            guard let url = ShareCard.storeURL else { return }
            qr = await Task.detached(priority: .utility) {
                guard let image = QR.image(url.absoluteString) else { return nil as CGImage? }
                return CIContext().createCGImage(image, from: image.extent)
            }.value
        }
    }
}

extension UTType {
    static let soloSettings = UTType(exportedAs: "com.hgsldswk.solocheckin.settings")
}

struct CodesScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var includeZone = true
    @State private var imported: DailyRule?
    @State private var picker = false
    @State private var confirm = false
    @State private var saving = false

    var body: some View {
        Screen(title: L.t("code.title"), subtitle: L.t("code.privacy")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(L.t("code.includeZone"), isOn: $includeZone).accessibilityIdentifier("code.includeZone")
                Text(ShareCode.encode(model.rule, includeZone: includeZone)).font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled).accessibilityIdentifier("code.value")
                PrimaryButton(title: L.t("code.copy"), symbol: "doc.on.doc", id: "code.copy", primary: false) {
                    if !Launch.testing { UIPasteboard.general.string = ShareCode.encode(model.rule, includeZone: includeZone) }
                    model.message = "code.copied"
                }
                PrimaryButton(title: L.t("code.export"), symbol: "square.and.arrow.up", id: "code.export", primary: false) {
                    let value = ShareCode.encode(model.rule, includeZone: includeZone)
                    Task {
                        do { model.requestShare([try await ExportFile.write(value, extension: ShareCode.fileExtension)]) }
                        catch { model.error = "error.share" }
                    }
                }
            }.modifier(Surface())
            VStack(alignment: .leading, spacing: 8) {
                if !Launch.testing {
                    PasteButton(payloadType: String.self) { strings in
                        if let string = strings.first { parse(string) }
                    }
                    .buttonBorderShape(.capsule).frame(minHeight: 44).accessibilityIdentifier("code.paste")
                } else if let value = ProcessInfo.processInfo.environment["SOLO_TEST_CODE"] {
                    PrimaryButton(title: L.t("code.paste"), symbol: "doc.on.clipboard", id: "code.paste", primary: false) { parse(value) }
                }
                PrimaryButton(title: L.t("code.importFile"), symbol: "folder", id: "code.file", primary: false) { picker = true }
            }.modifier(Surface())
            if let imported {
                let deadline = imported.deadline(on: model.now) ?? model.now
                VStack(alignment: .leading, spacing: 8) {
                    IconRow(title: L.t("code.preview"), subtitle: L.f("code.summary", L.clock(deadline, zone: imported.zone), imported.grace),
                            symbol: "clock", tone: .mint)
                    LocalTimes(date: deadline.addingTimeInterval(Double(imported.grace) * 60), zone: imported.zone)
                    PrimaryButton(title: L.t("code.apply"), symbol: "checkmark", id: "code.apply") {
                        if model.data.outgoing.contains(where: { !$0.ended }) { confirm = true } else { apply() }
                    }.disabled(saving)
                }.modifier(Surface())
            }
        }
        .task(id: model.pendingCodeFile) {
            if let url = model.pendingCodeFile {
                await load(url)
                model.pendingCodeFile = nil
            }
        }
        .task(id: model.pendingCodeText) {
            if let value = model.pendingCodeText {
                parse(value)
                model.pendingCodeText = nil
            }
        }
        .fileImporter(isPresented: $picker, allowedContentTypes: [.soloSettings, .plainText]) { result in
            if case let .success(url) = result { Task { await load(url) } }
        }
        .confirmationDialog(L.t("plan.confirm"), isPresented: $confirm, titleVisibility: .visible) {
            Button(L.t("code.apply")) { apply() }
        } message: { Text(L.t("status.waitingNote")) }
    }

    private func load(_ url: URL) async {
        do {
            let value = try await Task.detached {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom: url)
                defer { try? file.close() }
                guard let data = try file.read(upToCount: 513), data.count <= 512,
                      let value = String(data: data, encoding: .utf8) else { throw CodeError.invalid }
                return value
            }.value
            parse(value)
        } catch { model.error = "error.code" }
    }

    private func parse(_ value: String) {
        do { imported = try ShareCode.decode(value) }
        catch { imported = nil; model.error = "error.code" }
    }

    private func apply() {
        guard let imported else { return }
        saving = true
        var plan = model.data.plan.next ?? model.data.plan.current
        plan.rule = imported
        Task {
            if await model.save(plan: plan) { dismiss() }
            saving = false
        }
    }
}

enum ExportFile {
    private static var folder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SoloExports", isDirectory: true)
    }

    static func clear() async {
        _ = await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder)
        }.value
    }

    static func write(_ text: String, extension ext: String) async throws -> URL {
        try await Task.detached {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dayAgo = Date().addingTimeInterval(-86_400)
            let old = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey])
            for url in old {
                if let date = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate, date < dayAgo {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            let filename = "SoloCheckIn-" + UUID().uuidString.prefix(8)
            let url = folder.appendingPathComponent(String(filename)).appendingPathExtension(ext)
            try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
            return url
        }.value
    }
}
