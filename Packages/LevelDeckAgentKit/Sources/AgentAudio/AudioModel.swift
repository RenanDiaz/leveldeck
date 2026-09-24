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
    /// Dispositivos que se pueden elegir, por scope.
    public private(set) var deviceLists: [Scope: [DeviceInfo]] = [:]
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

    public func devices(_ scope: Scope) -> [DeviceInfo] {
        deviceLists[scope] ?? []
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

    /// Vuelve a suscribir los listeners y relee ambos scopes. Se usa al despertar la Mac: los
    /// dispositivos pueden haber cambiado mientras dormía (SPEC §5.2). Si no estaba corriendo,
    /// arranca.
    public func restart() {
        guard isRunning else {
            start()
            return
        }
        controller.stopObserving()
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

    /// Relee la lista de dispositivos y el canal de un scope. Son lecturas independientes: si
    /// una falla, conserva su último valor y la otra se aplica igual. Al desconectar el
    /// dispositivo activo, la HAL puede fallar un instante al leer el default viejo, y la
    /// lista tiene que actualizarse de todas formas.
    public func refresh(_ scope: Scope) {
        var failure: AudioControlError?
        var readAny = false
        do throws(AudioControlError) {
            deviceLists[scope] = try controller.devices(scope)
            readAny = true
        } catch {
            failure = error
        }
        do throws(AudioControlError) {
            channels[scope] = try controller.channel(scope)
            readAny = true
        } catch {
            failure = error
        }
        lastError = failure
        if readAny {
            onChange?()
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

    /// Cambia el dispositivo por defecto del scope. Elegir el que ya está activo no hace nada.
    /// Si falla (p. ej. el dispositivo se desconectó), se resincroniza la lista con el sistema.
    public func setDefaultDevice(_ deviceId: String, scope: Scope) {
        guard channels[scope]?.deviceId != deviceId else {
            lastError = nil
            return
        }
        perform(scope) { () throws(AudioControlError) in
            try controller.setDefaultDevice(deviceId, scope: scope)
            // Leer el canal nuevo ya, sin esperar al listener (que llega después y no cambia nada).
            refresh(scope)
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
