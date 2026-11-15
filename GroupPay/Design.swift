import SwiftUI

enum GP {
    static let background = Color(red: 0.039, green: 0.082, blue: 0.067)
    static let surface = Color(red: 0.074, green: 0.129, blue: 0.106)
    static let raised = Color(red: 0.118, green: 0.188, blue: 0.157)
    static let text = Color(red: 0.953, green: 0.957, blue: 0.914)
    static let mint = Color(red: 0.761, green: 0.941, blue: 0.667)
    static let secondary = Color(red: 0.663, green: 0.737, blue: 0.682)
    static let amber = Color(red: 0.973, green: 0.792, blue: 0.565)
    static let border = Color(red: 0.70, green: 0.83, blue: 0.73).opacity(0.09)
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(GP.text)
            .background(GP.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(GP.border))
    }
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(enabled ? GP.background : GP.secondary)
            .background(enabled ? GP.mint : GP.raised, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            .opacity(enabled && configuration.isPressed ? 0.84 : 1)
            .scaleEffect(enabled && configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
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
        let palette = [GP.mint,
                       Color(red: 0.79, green: 0.76, blue: 0.91),
                       Color(red: 0.95, green: 0.77, blue: 0.61),
                       Color(red: 0.65, green: 0.82, blue: 0.84)]
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
        return bill.status == .collecting && !bill.allApproved ? GP.amber : GP.mint
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
            Text(title).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
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
            Text(title).font(.largeTitle.weight(.semibold)).tracking(-0.8)
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
    func gpPage() -> some View {
        self.foregroundStyle(GP.text)
            .background(GP.background.ignoresSafeArea())
            .toolbarBackground(GP.background, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
    }
    func gpField() -> some View {
        self.padding(.horizontal, 15).padding(.vertical, 14)
            .foregroundStyle(GP.text)
            .background(GP.raised, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(GP.border))
    }
}
