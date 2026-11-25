import AppIntents
import SwiftUI
import WidgetKit

struct CheckInWidgetEntry: TimelineEntry {
    var date: Date
    var checked: Date?
}

struct CheckInWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> CheckInWidgetEntry { CheckInWidgetEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (CheckInWidgetEntry) -> Void) {
        Task {
            let date = Date()
            let state = try? await LocalStore.read()
            completion(CheckInWidgetEntry(date: date, checked: state?.checkIn(at: date)?.clicked))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CheckInWidgetEntry>) -> Void) {
        Task {
            let now = Date()
            let state = try? await LocalStore.read()
            let rule = state?.plan.current.rule ?? DailyRule()
            let windows = state?.plan.windows(around: now) ?? []
            let changes = ([rule.followingDay(after: now)] + windows.flatMap {
                [$0.opens, $0.deadline, $0.expiry.addingTimeInterval(1)]
            }).filter { $0 > now && $0.timeIntervalSince(now) < 36 * 3600 }
            let entries = ([now] + Array(Set(changes)).sorted()).map { date in
                CheckInWidgetEntry(date: date, checked: state?.checkIn(at: date)?.clicked)
            }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(6 * 3600))))
        }
    }
}

struct CheckInWidgetView: View {
    let entry: CheckInWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L.t("app.name"), systemImage: "house.fill").font(.caption.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if let date = entry.checked {
                Label(L.f("home.doneAt", L.clock(date)), systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(Color(red: 0.12, green: 0.38, blue: 0.30))
            } else {
                Button(intent: CheckInIntent()) {
                    Label(L.t("home.check"), systemImage: "checkmark.circle").font(.headline)
                }
                .buttonStyle(.borderedProminent).tint(Color(red: 0.14, green: 0.42, blue: 0.63))
                .accessibilityIdentifier("widget.check")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.89, green: 0.95, blue: 0.99), Color(red: 1, green: 0.97, blue: 0.92)],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
        }
        .widgetURL(URL(string: "solocheckin://check"))
    }
}

@main
struct SoloCheckInWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SoloCheckInWidget", provider: CheckInWidgetProvider()) { entry in
            CheckInWidgetView(entry: entry)
        }
        .configurationDisplayName(L.t("widget.title"))
        .description(L.t("widget.description"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
