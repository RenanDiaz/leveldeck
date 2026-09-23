/// Versión del protocolo de mensajes (SPEC §8). Viaja como `v` en `hello` y `state`.
public enum ProtocolVersion {
    /// v2 (Fase 4): `settable` pasa a `volumeSettable`.
    public static let current = 2
}
