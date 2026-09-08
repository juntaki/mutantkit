import SwiftUI

struct ContentView: View {
    @State private var tapCount = 0

    /// The only plain-Swift logic in this fixture, and covered exclusively by
    /// `testTappingFarFromTextStillTriggersAction` — no unit test target
    /// exists in this fixture at all. Its boundary (`>= 0`) exists purely so
    /// a real, already-registered built-in operator (relational-boundary
    /// mutation, not anything new landed by this task) has one real mutant
    /// to discover and kill exclusively through the UI test target, proving
    /// the substrate carries a real mutation end to end through
    /// `mutantkit plan` + `mutantkit run` — not just a hand-applied edit.
    static func isRowTapRegistered(currentCount: Int) -> Bool {
        currentCount >= 0
    }

    var body: some View {
        VStack(spacing: 24) {
            // Icon-only button. Its accessible name comes entirely from the
            // explicit `.accessibilityLabel` below. Deliberately a hand-drawn
            // `Path`, not an SF Symbol image: a symbol like `"xmark"` carries
            // its own non-empty system-provided default accessibility
            // description ("Close", confirmed empirically — removing the
            // explicit label alone did not reproduce a RED accessibility
            // test), which would silently mask the exact fault this fixture
            // exists to make observable only through `.accessibilityLabel`.
            // A plain stroked path has no inherent semantic meaning and so
            // no default label of any kind.
            Button {
                // Close action. Intentionally has nothing else to observe:
                // the label is the only thing under test here.
            } label: {
                CloseGlyph()
                    .stroke(lineWidth: 2)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .accessibilityIdentifier("closeButton")

            // Wide, plain-content button row. Without `.contentShape`, a
            // SwiftUI `Button`'s real hit area is only the union of its
            // label's actually-drawn content (the two `Text` glyphs here) —
            // the empty space between them, despite being visually part of
            // the row, does not register a tap. `.contentShape(Rectangle())`
            // extends the hit area to the row's full frame.
            Button {
                if Self.isRowTapRegistered(currentCount: tapCount) {
                    tapCount += 1
                }
            } label: {
                HStack {
                    Text("Item")
                    Spacer()
                    Text("$9.99")
                }
                .padding()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("itemRow")

            Text("Taps: \(tapCount)")
                .accessibilityIdentifier("tapCountLabel")
        }
        .padding()
    }
}

/// A plain "X" glyph, drawn rather than an SF Symbol so it carries no
/// system-provided default accessibility description of its own — see the
/// close button's own comment above for why that distinction matters here.
private struct CloseGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}
