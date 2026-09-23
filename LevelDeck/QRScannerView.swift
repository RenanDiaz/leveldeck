import AVFoundation
import SwiftUI
import UIKit

/// Vista previa de la cámara que entrega el primer QR que lee (SPEC §7, AVFoundation).
struct QRScannerView: UIViewRepresentable {
    let onCode: @MainActor (String) -> Void

    func makeUIView(context: Context) -> ScannerPreview {
        let view = ScannerPreview()
        view.controller.onCode = onCode
        view.controller.start(on: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: ScannerPreview, context: Context) {
        uiView.controller.onCode = onCode
    }

    static func dismantleUIView(_ uiView: ScannerPreview, coordinator: ()) {
        uiView.controller.stop()
    }
}

final class ScannerPreview: UIView {
    let controller = ScannerController()

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // `layerClass` garantiza el tipo.
        layer as! AVCaptureVideoPreviewLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("No se usa desde storyboards.")
    }
}

/// Maneja la `AVCaptureSession` en su propia cola; los QR llegan en la principal.
final class ScannerController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    @MainActor var onCode: (@MainActor (String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.renandiaz.LevelDeck.scanner")
    /// Un QR se entrega una sola vez por sesión de escaneo.
    private var didDeliver = false

    @MainActor
    func start(on layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
        sessionQueue.async {
            let session = self.session
            guard session.inputs.isEmpty,
                  let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                if output.availableMetadataObjectTypes.contains(.qr) {
                    output.metadataObjectTypes = [.qr]
                }
            }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    @MainActor
    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let text = metadataObjects
            .compactMap { $0 as? AVMetadataMachineReadableCodeObject }
            .first { $0.type == .qr }?
            .stringValue
        guard let text else { return }
        // El delegate está registrado con la cola principal.
        MainActor.assumeIsolated {
            guard !didDeliver else { return }
            didDeliver = true
            onCode?(text)
        }
    }
}
