/// Message protocol version (SPEC §8). Travels as `v` in `hello` and `state`.
public enum ProtocolVersion {
    /// v2 (Phase 4): `settable` becomes `volumeSettable`.
    /// v3 (Phase 5): the agent opens with `challenge` and `hello` carries `proof` (SPEC §8).
    public static let current = 3
}
