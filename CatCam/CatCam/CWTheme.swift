import SwiftUI

enum CWTheme {
    static let pink = Color(red: 1.00, green: 0.44, blue: 0.62)
    static let pinkDeep = Color(red: 0.90, green: 0.27, blue: 0.48)
    static let pinkSoft = Color(red: 1.00, green: 0.93, blue: 0.95)
    static let mint = Color(red: 0.16, green: 0.68, blue: 0.51)
    static let coral = Color(red: 0.94, green: 0.33, blue: 0.38)
    static let amber = Color(red: 0.96, green: 0.58, blue: 0.18)
    static let ink = Color(red: 0.27, green: 0.17, blue: 0.21)
    static let sub = Color(red: 0.60, green: 0.49, blue: 0.54)
}

struct CWBackground: View {
    var body: some View {
        LinearGradient(colors: [CWTheme.pinkSoft, Color(.systemGroupedBackground)],
                       startPoint: .top,
                       endPoint: .center)
            .ignoresSafeArea()
    }
}

struct CWCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct CWPillButton: View {
    let title: String
    let systemImage: String
    var filled: Bool = true
    var tint: Color = CWTheme.pink
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundColor(filled ? .white : tint)
            .background(filled ? tint : tint.opacity(0.14))
            .clipShape(Capsule())
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct CWDot: View {
    let lamp: CWLamp

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
    }

    private var color: Color {
        switch lamp {
        case .up:
            return CWTheme.mint
        case .down:
            return CWTheme.coral
        case .checking:
            return CWTheme.amber
        case .unknown, .off:
            return Color.gray.opacity(0.4)
        }
    }
}
