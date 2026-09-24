/// Versión del protocolo de mensajes (SPEC §8). Viaja como `v` en `hello` y `state`.
public enum ProtocolVersion {
    /// v2 (Fase 4): `settable` pasa a `volumeSettable`.
    /// v3 (Fase 5): el agente abre con `challenge` y el `hello` lleva `proof` (SPEC §8).
    public static let current = 3
}
