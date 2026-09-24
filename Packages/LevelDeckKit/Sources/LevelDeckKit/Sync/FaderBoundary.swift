/// Bordes del fader que dan feedback háptico (SPEC §6.2): 0 % y 100 %.
public enum FaderBoundary: Equatable, Sendable {
    case minimum
    case maximum

    /// El borde al que llega el fader al pasar de `old` a `new`, si antes no estaba en él.
    /// Quedarse en el borde no lo repite; salir y volver, sí.
    public static func reached(from old: Float, to new: Float) -> FaderBoundary? {
        if new <= 0, old > 0 { return .minimum }
        if new >= 1, old < 1 { return .maximum }
        return nil
    }
}
