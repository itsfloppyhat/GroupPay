import SwiftUI

enum GP {
    static let background = Color(red: 0.045, green: 0.065, blue: 0.065)
    static let surface = Color(red: 0.085, green: 0.11, blue: 0.11)
    static let raised = Color(red: 0.13, green: 0.16, blue: 0.16)
    static let mint = Color(red: 0.70, green: 0.96, blue: 0.64)
    static let secondary = Color(red: 0.61, green: 0.68, blue: 0.65)
    static let amber = Color(red: 1, green: 0.78, blue: 0.48)
}

struct Panel<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(padding).frame(maxWidth: .infinity, alignment: .leading)
            .background(GP.surface, in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.045)))
    }
}
struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.subheadline, design: .rounded, weight: .bold))
            .frame(maxWidth: .infinity).padding(.vertical, 17)
            .foregroundStyle(GP.background).background(GP.mint, in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
    }
}
struct Eyebrow: View {
    var text: String
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(GP.secondary) }
}
struct Avatar: View {
    var name: String
    var index: Int = 0
    var size: CGFloat = 36
    private var tint: Color { [GP.mint, .init(red: 0.73, green: 0.73, blue: 1), .init(red: 1, green: 0.78, blue: 0.58), .init(red: 0.62, green: 0.84, blue: 1)][abs(index) % 4] }
    var body: some View {
        Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(tint).frame(width: size, height: size).background(tint.opacity(0.13), in: Circle())
            .overlay(Circle().strokeBorder(GP.background, lineWidth: 2)).accessibilityLabel(name)
    }
}
struct StatusPill: View {
    var bill: Bill
    var label: String { bill.status == .paid ? "Paid" : bill.status == .cardReady ? "Card ready" : bill.allApproved ? "Ready to confirm" : "Awaiting approval" }
    var body: some View {
        Text(label).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 10).padding(.vertical, 6)
            .foregroundStyle(bill.status == .collecting && !bill.allApproved ? GP.amber : GP.mint)
            .background((bill.status == .collecting && !bill.allApproved ? GP.amber : GP.mint).opacity(0.10), in: Capsule())
    }
}
struct EmptyPanel: View {
    var symbol: String
    var title: String
    var subtitle: String
    var body: some View {
        Panel {
            Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(GP.mint).padding(.bottom, 8)
            Text(title).font(.title3.bold())
            Text(subtitle).font(.subheadline).foregroundStyle(GP.secondary)
        }
    }
}
struct PageHeading: View {
    var overline: String
    var title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: overline)
            Text(title).font(.system(size: 34, weight: .semibold, design: .rounded)).tracking(-1)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}
extension View {
    func gpPage() -> some View { self.background(GP.background).toolbarBackground(GP.background, for: .navigationBar).toolbarColorScheme(.dark, for: .navigationBar) }
    func gpField() -> some View { self.padding(14).background(GP.raised, in: RoundedRectangle(cornerRadius: 12)) }
}
