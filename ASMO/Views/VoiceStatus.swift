import SwiftUI

/// What the voice is doing, shown where the capture pill sits: bars that follow your voice while listening,
/// then 转写 and 整理 so the wait after speaking is never silent.
enum VoicePhase: Equatable {
    case listening, transcribing, organizing
}

/// Bars driven by the microphone level, with a short memory so they ripple instead of jumping.
struct VoiceLevelBars: View {
    let voice: VoiceCapture
    var color: Color
    var count = 5
    @State private var history = LevelHistory()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { _ in
            let levels = history.push(voice.level(), count: count)
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(color)
                        .frame(width: 3, height: 4 + 14 * levels[index])
                }
            }
            .frame(height: 18)
            .animation(.linear(duration: 1 / 30), value: levels)
        }
    }

    /// A reference type so the timeline can update it while drawing.
    final class LevelHistory {
        private var values: [Double] = []
        private var smoothed = 0.0

        func push(_ level: Double, count: Int) -> [Double] {
            smoothed = smoothed * 0.55 + level * 0.45
            values.append(smoothed)
            if values.count > count { values.removeFirst(values.count - count) }
            let padded = Array(repeating: 0.0, count: max(0, count - values.count)) + values
            // Middle bars a little taller: reads as a voice, not a meter.
            return padded.enumerated().map { index, value in
                let center = 1 - abs(Double(index) - Double(count - 1) / 2) / Double(count) * 0.8
                return min(1, value * center * 1.15)
            }
        }
    }
}

/// Three dots that breathe in turn: "working on it".
struct WorkingDots: View {
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = (sin(time * 5 - Double(index) * 0.9) + 1) / 2
                    Circle().fill(color.opacity(0.35 + 0.65 * phase))
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.75 + 0.35 * phase)
                }
            }
        }
    }
}

/// The floating status pill (page and bar voice): listening → transcribing → organizing.
struct VoiceStatusPill: View {
    let phase: VoicePhase
    let voice: VoiceCapture
    let theme: PlannerTheme
    /// Stops listening (and files what was said).
    var stop: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .listening:
                VoiceLevelBars(voice: voice, color: theme.accent)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(elapsed(context.date)).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(theme.quiet)
                }
                Text("正在听").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.ink)
                if let stop {
                    Button(action: stop) {
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 2).fill(theme.onAccent).frame(width: 8, height: 8)
                            Text("说完了").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.onAccent)
                        }
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(theme.accent, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("停止并整理")
                }
            case .transcribing:
                WorkingDots(color: theme.accent)
                Text("正在转写…").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.ink)
            case .organizing:
                WorkingDots(color: theme.accent)
                Text("正在整理成待办…").font(.system(size: 13, weight: .medium)).foregroundStyle(theme.ink)
            }
        }
        .padding(.leading, 14).padding(.trailing, phase == .listening && stop != nil ? 5 : 16)
        .frame(height: 36)
        .floatingSurface(theme)
        .animation(.smooth(duration: 0.2), value: phase)
    }

    private func elapsed(_ now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(voice.startedAt ?? now))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
