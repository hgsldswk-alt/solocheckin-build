import SwiftUI

enum Palette {
    static let paper = Color(red: 250 / 255, green: 247 / 255, blue: 242 / 255)
    static let ink = Color(red: 35 / 255, green: 53 / 255, blue: 67 / 255)
    static let muted = Color(red: 83 / 255, green: 104 / 255, blue: 116 / 255)
    static let blue = Color(red: 62 / 255, green: 142 / 255, blue: 208 / 255)
    static let action = Color(red: 35 / 255, green: 106 / 255, blue: 161 / 255)
    static let sky = Color(red: 232 / 255, green: 243 / 255, blue: 252 / 255)
    static let orange = Color(red: 242 / 255, green: 166 / 255, blue: 90 / 255)
    static let mint = Color(red: 93 / 255, green: 187 / 255, blue: 154 / 255)
    static let coral = Color(red: 232 / 255, green: 115 / 255, blue: 92 / 255)
}

enum Tone {
    case sky, sun, mint, missed, neutral
    var fill: Color {
        switch self {
        case .sky: Palette.sky
        case .sun: Palette.orange.opacity(0.23)
        case .mint: Palette.mint.opacity(0.22)
        case .missed: Palette.coral.opacity(0.19)
        case .neutral: Palette.muted.opacity(0.09)
        }
    }
    var ink: Color {
        switch self {
        case .sky: Palette.action
        case .sun: Color(red: 0.49, green: 0.29, blue: 0.10)
        case .mint: Color(red: 0.12, green: 0.38, blue: 0.30)
        case .missed: Color(red: 0.55, green: 0.22, blue: 0.14)
        case .neutral: Palette.muted
        }
    }
}

struct Surface: ViewModifier {
    var fill: Color = .white
    func body(content: Content) -> some View {
        content.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 19))
            .shadow(color: Palette.ink.opacity(0.065), radius: 12, y: 4)
    }
}

struct Screen<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }
                }
                content
            }
            .padding(.horizontal, 19).padding(.top, 12).padding(.bottom, 22)
            .frame(maxWidth: 580)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Palette.paper.ignoresSafeArea())
        .foregroundStyle(Palette.ink)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HeroCard<Content: View>: View {
    var symbol: String
    var tone: Tone = .sky
    @ViewBuilder let content: Content
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 21)
                .fill(LinearGradient(colors: [tone.fill, Palette.paper], startPoint: .topTrailing, endPoint: .bottomLeading))
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Circle().fill(tone.fill).frame(width: 96, height: 96).offset(x: 7, y: -2)
                    Image(systemName: "sun.max.fill").font(.system(size: 25)).foregroundStyle(Palette.orange)
                        .offset(x: 8, y: -12)
                    Image(systemName: symbol).font(.system(size: 61, weight: .light))
                        .symbolRenderingMode(.hierarchical).foregroundStyle(tone.ink)
                        .padding(13)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(21)
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(16).padding(.top, 54)
        }
        .frame(minHeight: 168)
        .overlay(RoundedRectangle(cornerRadius: 21).strokeBorder(tone.fill, lineWidth: 1))
    }
}

struct Glyph: View {
    let name: String
    var tone: Tone = .sky
    var size: CGFloat = 38
    var body: some View {
        Image(systemName: name).font(.system(size: size * 0.45, weight: .semibold))
            .frame(width: size, height: size).background(tone.fill, in: RoundedRectangle(cornerRadius: size / 3))
            .foregroundStyle(tone.ink).accessibilityHidden(true)
    }
}

struct IconTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tone: Tone = .sky
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Glyph(name: symbol, tone: tone)
            Text(title).font(.headline)
            Text(subtitle).font(.footnote).foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .modifier(Surface())
    }
}

struct IconRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    var tone: Tone = .sky
    var arrow = false
    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Glyph(name: symbol, tone: tone)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 0)
            if arrow {
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct StatusPill: View {
    let title: String
    let symbol: String
    var tone: Tone = .sky
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            .padding(.vertical, 5).padding(.horizontal, 9).background(tone.fill, in: Capsule())
            .foregroundStyle(tone.ink)
    }
}

struct EmptyIllustration: View {
    let symbol: String
    var body: some View {
        HStack(spacing: 3) {
            Glyph(name: "sun.max", tone: .sun).rotationEffect(.degrees(-12)).offset(y: 7)
            Glyph(name: symbol, tone: .sky, size: 57)
            Glyph(name: "heart", tone: .mint).rotationEffect(.degrees(12)).offset(y: -4)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

struct ActionLabel: View {
    let title: String
    let symbol: String
    var primary = true
    var tone: Tone = .sky
    var body: some View {
        Label(title, systemImage: symbol).font(primary ? .headline : .subheadline.weight(.semibold))
            .multilineTextAlignment(.center).padding(.vertical, 7).padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: primary ? 52 : 44)
            .foregroundStyle(primary ? .white : tone.ink)
            .background(primary ? Palette.action : tone.fill, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}

struct PrimaryButton: View {
    let title: String
    let symbol: String
    let id: String
    var primary = true
    var tone: Tone = .sky
    let action: () -> Void
    var body: some View {
        Button(action: action) { ActionLabel(title: title, symbol: symbol, primary: primary, tone: tone) }
            .buttonStyle(.plain)
            .accessibilityIdentifier(id)
    }
}

struct RouteRow: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String
    let id: String
    let route: Route
    var tone: Tone = .sky
    var body: some View {
        NavigationLink(value: route) { IconRow(title: title, subtitle: subtitle, symbol: symbol, tone: tone, arrow: true) }
            .buttonStyle(.plain).accessibilityIdentifier(id)
    }
}

struct Footnote: View {
    let text: String
    var body: some View { Text(text).font(.footnote).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true) }
}

struct GracePicker: View {
    @Binding var grace: Int
    var id = "plan.grace"
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) { options }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) { options }
        }
    }
    private var options: some View {
        ForEach(DailyRule.graceOptions, id: \.self) { value in
            Button {
                grace = value
            } label: {
                Text(L.f("plan.minutes", value)).font(.subheadline.weight(.medium)).fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 44)
                    .background(grace == value ? Tone.sky.fill : Tone.neutral.fill, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(grace == value ? Palette.action : Palette.ink)
            }
            .buttonStyle(.plain).accessibilityIdentifier("\(id).\(value)")
            .accessibilityAddTraits(grace == value ? .isSelected : [])
        }
    }
}
