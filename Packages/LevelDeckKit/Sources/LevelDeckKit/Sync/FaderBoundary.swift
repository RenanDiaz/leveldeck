/// Fader edges that give haptic feedback (SPEC §6.2): 0 % and 100 %.
public enum FaderBoundary: Equatable, Sendable {
    case minimum
    case maximum

    /// The edge the fader reaches when going from `old` to `new`, if it was not already on it.
    /// Staying on the edge does not repeat it; leaving and coming back does.
    public static func reached(from old: Float, to new: Float) -> FaderBoundary? {
        if new <= 0, old > 0 { return .minimum }
        if new >= 1, old < 1 { return .maximum }
        return nil
    }
}
