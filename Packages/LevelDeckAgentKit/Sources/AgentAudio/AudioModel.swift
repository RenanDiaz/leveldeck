import LevelDeckKit
import Observation

/// Estado de audio observable que consume la UI del agente.
///
/// Es la única fuente de verdad del lado de la Mac: tanto las acciones del menú como los
/// cambios externos (teclado, Ajustes del Sistema, cambio de dispositivo) terminan aquí.
@MainActor
@Observable
public final class AudioModel {
    /// Canal por scope. Si falta la clave, no hay dispositivo por defecto para ese scope.
    public private(set) var channels: [Scope: AudioChannel] = [:]
    /// Último error de una lectura o escritura. Se limpia con la siguiente operación exitosa.
    public private(set) var lastError: AudioControlError?

    /// Se llama después de cada lectura o escritura exitosa, venga del menú, de un cliente
    /// remoto o de fuera. El servidor la usa para enviar `state`; él mismo descarta repetidos.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    private let controller: any AudioControlling
    @ObservationIgnored public private(set) var isRunning = false

    public init(controller: any AudioControlling) {
        self.controller = controller
    }

    public func channel(_ scope: Scope) -> AudioChannel? {
        channels[scope]
    }

    public func canSetVolume(_ scope: Scope) -> Bool {
        channels[scope]?.volumeSettable ?? false
    }

    public func canSetMute(_ scope: Scope) -> Bool {
        channels[scope]?.muteSettable ?? false
    }

    /// Lee ambos scopes y empieza a escuchar cambios. Idempotente.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        for scope in Scope.allCases {
            refresh(scope)
        }
        controller.startObserving { [weak self] scope in
            self?.refresh(scope)
        }
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        controller.stopObserving()
    }

    /// Relee el canal completo de un scope. Si la lectura falla, conserva el último estado.
    public func refresh(_ scope: Scope) {
        do throws(AudioControlError) {
            channels[scope] = try controller.channel(scope)
            lastError = nil
            onChange?()
        } catch {
            lastError = error
        }
    }

    public func setVolume(_ value: Float, scope: Scope) {
        guard Volume.isValid(value) else {
            lastError = .invalidValue
            return
        }
        guard let channel = channels[scope] else {
            lastError = .noDevice(scope)
            return
        }
        guard channel.volumeSettable else {
            lastError = .notSettable(scope)
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setVolume(value, scope: scope)
            channels[scope]?.volume = value
        }
    }

    public func setMute(_ muted: Bool, scope: Scope) {
        guard let channel = channels[scope] else {
            lastError = .noDevice(scope)
            return
        }
        guard channel.muteSettable else {
            lastError = .notSettable(scope)
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setMute(muted, scope: scope)
            channels[scope]?.muted = muted
        }
    }

    /// Ejecuta una escritura. Si falla, registra el error y resincroniza con el sistema.
    private func perform(_ scope: Scope, _ write: () throws(AudioControlError) -> Void) {
        do throws(AudioControlError) {
            try write()
            lastError = nil
            onChange?()
        } catch {
            refresh(scope)
            lastError = error
        }
    }
}
