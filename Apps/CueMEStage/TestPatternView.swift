import SwiftUI
import StageKit

/// A monitor's picture of a running test pattern, with a "TEST" label so it is never mistaken for live content.
struct TestPatternView: View {
    let pattern: TestPattern
    @Environment(\.theme) private var theme

    /// 75 % colour bars, in the usual order.
    private static let bars: [Color] = [
        Color(hex: 0xBFBFBF), Color(hex: 0xBFBF00), Color(hex: 0x00BFBF), Color(hex: 0x00BF00),
        Color(hex: 0xBF00BF), Color(hex: 0xBF0000), Color(hex: 0x0000BF),
    ]

    var body: some View {
        ZStack {
            switch pattern {
            case .bars:
                HStack(spacing: 0) {
                    ForEach(Self.bars.indices, id: \.self) { Self.bars[$0] }
                }
            case .grid:
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    var lines = Path()
                    let step = size.width / 16
                    var x: CGFloat = 0
                    while x <= size.width { lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                    var y: CGFloat = 0
                    while y <= size.height { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                    context.stroke(lines, with: .color(.white.opacity(0.8)), lineWidth: 0.5)
                    let c = CGPoint(x: size.width / 2, y: size.height / 2), r = min(size.width, size.height) * 0.4
                    context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(.white), lineWidth: 1)
                }
            }
            Text("TEST")
                .font(ThemeTokens.mono(12, weight: .bold))
                .foregroundStyle(.black)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(theme.warning, in: RoundedRectangle(cornerRadius: 3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Test pattern: \(pattern.title)")
    }
}
