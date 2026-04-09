import SwiftUI
import AVFoundation

/// Live camera QR code scanner using AVCaptureSession.
/// Calls onDetected once when a QR payload is found, then pauses capture.
struct CameraQRScannerView: UIViewRepresentable {
    let onDetected: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDetected: onDetected)
    }

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.setup(previewView: view)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewView, context: Context) {}

    // MARK: - Coordinator

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onDetected: (String) -> Void
        private var session: AVCaptureSession?
        private var hasDetected = false

        init(onDetected: @escaping (String) -> Void) {
            self.onDetected = onDetected
        }

        func setup(previewView: CameraPreviewView) {
            let session = AVCaptureSession()
            self.session = session

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            previewView.configure(session: session)

            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }

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
