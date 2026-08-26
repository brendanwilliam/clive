@preconcurrency import AVFoundation
import CliveCore
import SwiftUI

enum PairingTicketValidationError: Error { case expired, incompatibleVersion, invalidEndpoint, invalidPort, invalidFingerprint }

enum PairingTicketValidator {
    static func validate(_ ticket: PairingTicket, now: Date = .now) throws {
        guard ticket.expiresAt >= now else { throw PairingTicketValidationError.expired }
        guard ticket.protocolVersion == ProtocolFrame.version else { throw PairingTicketValidationError.incompatibleVersion }
        guard !ticket.endpoint.isEmpty else { throw PairingTicketValidationError.invalidEndpoint }
        guard ticket.port > 0 else { throw PairingTicketValidationError.invalidPort }
        guard ticket.daemonCertificateFingerprint.count == 64,
              ticket.daemonCertificateFingerprint.allSatisfy({ $0.isHexDigit }) else { throw PairingTicketValidationError.invalidFingerprint }
    }
}

struct PairingScannerView: UIViewControllerRepresentable {
    let onTicket: (PairingTicket) -> Void
    let onError: (Error) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController(); controller.delegate = context.coordinator; controller.onCancel = onCancel; return controller
    }
    func updateUIViewController(_ uiViewController: ScannerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor final class Coordinator: NSObject, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
        let parent: PairingScannerView; var consumed = false
        init(parent: PairingScannerView) { self.parent = parent }
        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !consumed, let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
            do {
                let ticket: PairingTicket
                if let url = URL(string: code), case .pairing(let linkTicket) = PairingLink.route(url) {
                    ticket = linkTicket
                } else {
                    ticket = try PairingPayload.decode(code)
                }
                try PairingTicketValidator.validate(ticket); consumed = true
                parent.onTicket(ticket)
            } catch { parent.onError(error) }
        }
    }
}

final class ScannerController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    var onCancel: (() -> Void)?
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input); let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }; session.addOutput(output)
        output.setMetadataObjectsDelegate(delegate, queue: .main); output.metadataObjectTypes = [.qr]
        let layer = AVCaptureVideoPreviewLayer(session: session); layer.videoGravity = .resizeAspectFill; layer.frame = view.bounds
        view.layer.addSublayer(layer); let captureSession = session
        let cancel = UIButton(type: .system)
        cancel.setTitle("Cancel", for: .normal); cancel.setTitleColor(.white, for: .normal)
        cancel.accessibilityIdentifier = "pairing-scanner-cancel"
        cancel.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(cancel)
        NSLayoutConstraint.activate([cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16)])
        DispatchQueue.global(qos: .userInitiated).async { captureSession.startRunning() }
    }
    override func viewDidDisappear(_ animated: Bool) { super.viewDidDisappear(animated); session.stopRunning() }
}
