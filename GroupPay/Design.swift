import SwiftUI

// Organic visual system from the supplied GroupPay prototype.
enum GP {
    static let background = Color(hex: 0xF5EAD8)
    static let surface = Color(hex: 0xEBDDC5)
    static let raised = Color(hex: 0xF9F4ED)
    static let text = Color(hex: 0x201E1D)
    static let accent = Color(hex: 0xC67139)
    // Existing call sites use mint for interactive text; this darker terracotta
    // keeps small labels legible on the light surfaces.
    static let mint = Color(hex: 0x8C491A)
    static let secondary = Color(hex: 0x645C50)
    static let amber = Color(hex: 0x8C491A)
    static let sage = Color(hex: 0x56633F)
    static let sageSurface = Color(hex: 0xE1EECC)
    static let peach = Color(hex: 0xFFE1D0)
    static let border = Color(hex: 0x201E1D).opacity(0.12)

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom("Caprasimo-Regular", size: size, relativeTo: style)
    }
    static func body(_ size: CGFloat = 17, weight: Font.Weight = .regular,
                     relativeTo style: Font.TextStyle = .body) -> Font {
        let name = weight == .bold ? "Figtree-Bold" : weight == .semibold || weight == .medium ? "Figtree-SemiBold" : "Figtree-Regular"
        return .custom(name, size: size, relativeTo: style)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

/// Only animates changes to the supplied visual state, never background refreshes.
private struct GPValueAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var value: Value
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .smooth(duration: 0.35), value: value)
    }
}

struct SoftPressButton: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct AnimatedSymbol: View {
    var name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: name)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffectsRemoved(reduceMotion)
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(GP.text)
            .background(GP.surface, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(GP.border))
            .shadow(color: GP.text.opacity(0.035), radius: 8, x: 0, y: 3)
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(GP.body(17, weight: .semibold, relativeTo: .headline))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(enabled ? GP.raised : GP.secondary)
            .background(enabled ? GP.mint : GP.surface, in: Capsule())
            .opacity(enabled && configuration.isPressed ? 0.84 : 1)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

struct Eyebrow: View {
    var text: String
    private var displayText: String {
        text == text.uppercased() ? text.lowercased().capitalized : text
    }
    var body: some View {
        Text(displayText)
            .font(.caption.weight(.medium)).tracking(0.25)
            .foregroundStyle(GP.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct Avatar: View {
    var name: String
    var index: Int = 0
    var size: CGFloat = 36
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1
    private var diameter: CGFloat { size * min(scale, 1.45) }
    private var tint: Color {
        let palette = [GP.mint, GP.sage, Color(hex: 0x765083), Color(hex: 0x356C73)]
        return palette[Int(index.magnitude % UInt(palette.count))]
    }
    private var initials: String {
        let parts = name.split(whereSeparator: \.isWhitespace)
        guard let first = parts.first?.first else { return "" }
        if parts.count > 1, let last = parts.last?.first { return String([first, last]).uppercased() }
        return String(first).uppercased()
    }
    var body: some View {
        Group {
            if initials.isEmpty { Image(systemName: "person.fill").font(.system(size: diameter * 0.34)) }
            else { Text(initials).font(.system(size: diameter * 0.32, weight: .semibold, design: .rounded)) }
        }
        .foregroundStyle(tint).frame(width: diameter, height: diameter)
        .background(tint.opacity(0.13), in: Circle())
        .overlay(Circle().strokeBorder(GP.background, lineWidth: 2))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Person" : name)
    }
}

struct StatusPill: View {
    var bill: Bill
    var label: String {
        switch bill.status {
        case .collecting: bill.allApproved ? "Ready to confirm" : "Awaiting approval"
        case .issuing: "Creating card"
        case .cardReady: "Card ready"
        case .paid: "Paid"
        case .cancelled: "Cancelled"
        }
    }
    private var tint: Color {
        if bill.status == .cancelled { return GP.secondary }
        return bill.status == .collecting && !bill.allApproved ? GP.amber : GP.sage
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(label).font(.caption2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .foregroundStyle(tint).background(tint.opacity(0.08), in: Capsule())
        .accessibilityElement(children: .ignore).accessibilityLabel(label)
    }
}

struct EmptyPanel: View {
    var symbol: String
    var title: String
    var subtitle: String
    var body: some View {
        Panel(padding: 24) {
            IconTile(symbol: symbol, size: 50).padding(.bottom, 5)
            Text(title).font(GP.display(22, relativeTo: .title3)).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.subheadline).foregroundStyle(GP.secondary)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct PageHeading: View {
    var overline: String
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Eyebrow(text: overline)
            Text(title).font(GP.display(34, relativeTo: .largeTitle)).tracking(-0.8)
                .foregroundStyle(GP.text).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
    }
}

struct TestModeBadge: View {
    var label: String = "Test mode"
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkle").font(.caption2).accessibilityHidden(true)
            Text(label).font(.caption2.weight(.medium))
        }
        .foregroundStyle(GP.mint)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(GP.mint.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(GP.mint.opacity(0.13)))
        .accessibilityElement(children: .combine)
    }
}

struct IconTile: View {
    var symbol: String
    var size: CGFloat = 46
    var tint: Color = GP.mint
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .regular))
            .foregroundStyle(tint).frame(width: size, height: size)
            .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.29, style: .continuous).strokeBorder(tint.opacity(0.08)))
            .accessibilityHidden(true)
    }
}

extension View {
    func gpAnimate<Value: Equatable>(_ value: Value) -> some View {
        modifier(GPValueAnimation(value: value))
    }

    func gpPage() -> some View {
        self.font(GP.body()).foregroundStyle(GP.text)
            .background(GP.background.ignoresSafeArea())
            .toolbarBackground(GP.background, for: .navigationBar)
            .toolbarColorScheme(.light, for: .navigationBar)
    }
    func gpField() -> some View {
        self.padding(.horizontal, 15).padding(.vertical, 14)
            .foregroundStyle(GP.text)
            .background(GP.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(GP.border))
    }
}
