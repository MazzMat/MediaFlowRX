import SwiftUI

/// The player is not observed. The timeline reads it only while this bar is on screen.
struct AudioMeter: View {
    let player: PreviewPlayer
    let active: Bool

    private let width: CGFloat = 96
    private let height: CGFloat = 6

    var body: some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { _ in
                meter(player.audioLevel())
            }
        } else {
            Text("—")
                .font(AppStyle.value)
                .foregroundStyle(.white)
        }
    }

    private func meter(_ level: AudioLevel) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(gradient)
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: width * fraction(level.rms))
                    }
                Rectangle()
                    .fill(color(for: level.peak))
                    .frame(width: 2)
                    .offset(x: max(0, width * fraction(level.peak) - 2))
                    .opacity(level.peak > AudioLevel.floor ? 1 : 0)
            }
            .frame(width: width, height: height)
            Text(peakText(level.peak))
                .font(AppStyle.value)
                .foregroundStyle(level.peak > -1 ? Color.red : Color.white)
                .monospacedDigit()
                .frame(minWidth: 52, alignment: .trailing)
        }
    }

    private var gradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .green, location: 0),
                .init(color: .green, location: fraction(-18)),
                .init(color: .yellow, location: fraction(-6)),
                .init(color: .red, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func fraction(_ db: Float) -> CGFloat {
        CGFloat((db - AudioLevel.floor) / -AudioLevel.floor).clamped(to: 0...1)
    }

    private func color(for db: Float) -> Color {
        if db > -1 { return .red }
        if db > -6 { return .yellow }
        return .white
    }

    private func peakText(_ db: Float) -> String {
        guard db > AudioLevel.floor else { return "-∞ dB" }
        return "\(Int(db.rounded())) dB"
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
