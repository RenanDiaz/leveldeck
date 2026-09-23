/// Tiempos de sincronización del fader (SPEC §6.2 y §8).
public enum SyncTiming {
    /// Máximo 30 envíos por segundo, tanto `setVolume` del cliente como `state` del agente.
    public static let minSendInterval: Duration = .seconds(1) / 30
    /// Tras soltar el fader, sus eventos de estado se siguen ignorando este tiempo.
    public static let echoHold: Duration = .milliseconds(300)
}

extension Duration {
    /// Para mostrar en pantalla (overlay de RTT).
    public var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
