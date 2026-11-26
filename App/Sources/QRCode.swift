@preconcurrency import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// Draws text as a QR code. CoreImage picks alphanumeric mode for our Base45 text.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            ContentUnavailableView("Couldn't draw the code", systemImage: "qrcode")
        }
    }

    /// Error correction level M (15%): survives screen glare and a slightly dirty lens.
    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }

    /// QR version (1–40) CoreImage chose for `text`, from the symbol width. For docs and tests.
    static func version(for text: String) -> Int? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let width = filter.outputImage?.extent.width else { return nil }
        // CoreImage adds one quiet-zone module on each side; a version-v symbol is 17 + 4v modules.
        return (Int(width) - 2 - 17) / 4
    }
}

/// Camera QR scanner (AVFoundation). Calls `onCode` once with the first QR code's text.
struct QRScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isCameraAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {
        controller.onCode = onCode
    }
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private nonisolated(unsafe) let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var delivered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        delivered = false
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = self.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        let text = objects.lazy.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }.first
        guard let text else { return }
        // Delivered on the main queue (see setMetadataObjectsDelegate above).
        MainActor.assumeIsolated {
            guard !delivered else { return }
            delivered = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(text)
        }
    }
}
