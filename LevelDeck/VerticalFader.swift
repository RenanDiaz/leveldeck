import SwiftUI

/// Vertical fader. Dragging is relative (moves from the current value, doesn't jump to the finger)
/// and reports start, changes and end so the mixer can handle throttle and echo suppression.
struct VerticalFader: View {
    let value: Float
    var isEnabled = true
    var isDimmed = false
    let onBegan: () -> Void
    let onChanged: (Float) -> Void
    let onEnded: (Float) -> Void

    /// Value when the drag started; `nil` if none is in progress.
    @State private var dragStart: Float?

    var body: some View {
        GeometryReader { geometry in
            let height = max(geometry.size.height, 1)
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 18)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 18)
                    .fill(isDimmed ? Color.secondary : Color.accentColor)
                    .frame(height: height * CGFloat(value))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let start: Float
                        if let dragStart {
                            start = dragStart
                        } else {
                            start = value
                            dragStart = value
                            onBegan()
                        }
                        onChanged(clamp(start - Float(gesture.translation.height / height)))
                    }
                    .onEnded { gesture in
                        let start = dragStart ?? value
                        dragStart = nil
                        onEnded(clamp(start - Float(gesture.translation.height / height)))
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
        .onChange(of: isEnabled) {
            // If it gets disabled mid-drag (e.g. the connection drops), end the drag.
            if !isEnabled, dragStart != nil {
                dragStart = nil
                onEnded(value)
            }
        }
        .accessibilityElement()
        .accessibilityValue(Text(Double(value), format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            let step: Float
            switch direction {
            case .increment: step = 0.05
            case .decrement: step = -0.05
            @unknown default: return
            }
            let target = clamp(value + step)
            onBegan()
            onChanged(target)
            onEnded(target)
        }
    }

    private func clamp(_ value: Float) -> Float {
        min(max(value, 0), 1)
    }
}
