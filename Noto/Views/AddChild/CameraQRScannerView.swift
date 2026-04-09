import SwiftUI
import AVFoundation

/// Live camera QR code scanner using AVCaptureSession.
/// Calls onDetected once when a QR payload is found, then stops capture.
/// Calls onError if camera setup fails (permission denied, hardware error, etc.)
struct CameraQRScannerView: UIViewRepresentable {
    let onDetected: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetected: onDetected, onError: onError)
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.setup(previewView: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stopSession()
    }

    // MARK: - Coordinator
    //
    // Thread model:
    // - setup() / stopSession() are called on the main thread (SwiftUI UIViewRepresentable lifecycle)
    // - metadataOutput delegate fires on .main (set via setMetadataObjectsDelegate queue: .main)
    // - startRunning() is dispatched to a background thread (it blocks until running)
    //
    // AVCaptureSession is not annotated Sendable by Apple, so we use nonisolated(unsafe)
    // to suppress the Swift 6 Sendable check. Thread safety is upheld by the access model above.

    // @unchecked Sendable: AVFoundation types (AVCaptureSession, AVCaptureDevice, etc.)
    // are not annotated Sendable by Apple. Thread safety is upheld manually — see
    // thread model above. This is the standard pattern for AVFoundation coordinators in Swift 6.
    final class Coordinator: NSObject, @unchecked Sendable, AVCaptureMetadataOutputObjectsDelegate {
        private let onDetected: (String) -> Void
        private let onError: (String) -> Void
        private var session: AVCaptureSession?
        private var hasDetected = false

        init(onDetected: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onDetected = onDetected
            self.onError = onError
        }

        // Called on main thread by SwiftUI
        func setup(previewView: CameraPreviewView) {
            let session = AVCaptureSession()
            self.session = session

            guard let device = AVCaptureDevice.default(for: .video) else {
                onError("Caméra inaccessible. Vérifiez les autorisations dans Réglages > nōto.")
                return
            }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                onError("Impossible d'accéder à la caméra : \(error.localizedDescription)")
                return
            }

            guard session.canAddInput(input) else {
                onError("La session caméra ne peut pas démarrer.")
                return
            }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                onError("Impossible de configurer la détection QR.")
                return
            }
            session.addOutput(output)
            // Delegate dispatched to main — hasDetected is only read/written on main thread
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            previewView.configure(session: session)

            // startRunning() blocks until running — must not be called on main thread
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        // Called on main thread by dismantleUIView
        func stopSession() {
            session?.stopRunning()
            session = nil
        }

        // Called on main thread (delegate queue = .main)
        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !hasDetected,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let payload = object.stringValue else { return }
            hasDetected = true
            session?.stopRunning()
            onDetected(payload)
        }
    }
}

// MARK: - Preview UIView

final class CameraPreviewView: UIView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    func configure(session: AVCaptureSession) {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = bounds
        self.layer.addSublayer(layer)
        self.previewLayer = layer
    }
}
