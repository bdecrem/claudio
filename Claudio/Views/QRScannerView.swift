import SwiftUI
import AVFoundation

struct QRScannerView: View {
    let onScanned: (_ url: String, _ token: String) -> Void
    let onCancel: () -> Void

    @State private var error: String?
    #if os(iOS)
    @State private var cameraAuthorized = false
    @State private var permissionDenied = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            #if os(iOS)
            if cameraAuthorized {
                QRCameraView { code in
                    guard let (url, token) = decodeQR(code) else {
                        error = "This doesn't look like an OpenClaw QR code. Make sure you're scanning the code from `openclaw qr`."
                        return
                    }
                    onScanned(url, token)
                }
                .ignoresSafeArea()
            }
            #endif

            VStack {
                HStack {
                    Spacer()
                    Button { onCancel() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding()
                }
                Spacer()

                #if os(iOS)
                if permissionDenied {
                    Text("Camera access is needed to scan QR codes.\nEnable it in Settings > Claudio.")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 60)
                } else if cameraAuthorized {
                    Text("Point at QR code on your computer")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.bottom, 60)
                }
                #elseif os(macOS)
                Text("QR scanning is not available on Mac.\nPaste your server URL directly in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 60)
                #endif
            }

            if let error {
                VStack(spacing: 16) {
                    Text(error)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Button("Try Again") {
                        self.error = nil
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                }
                .padding(24)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(32)
            }
        }
        #if os(iOS)
        .task {
            await requestCameraAccess()
        }
        #endif
    }

    #if os(iOS)
    private func requestCameraAccess() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            cameraAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAuthorized = granted
            permissionDenied = !granted
        default:
            permissionDenied = true
        }
    }
    #endif

    private func decodeQR(_ raw: String) -> (url: String, token: String)? {
        // Pad base64 if needed — OpenClaw QR codes may omit trailing '='
        var b64 = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let url = json["url"] as? String,
              let token = json["token"] as? String else {
            return nil
        }
        return (url, token)
    }
}

// MARK: - AVFoundation camera wrapper (iOS only)

#if os(iOS)
private struct QRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> QRCameraViewController {
        let vc = QRCameraViewController()
        vc.onCode = onCode
        return vc
    }

    func updateUIViewController(_ uiViewController: QRCameraViewController, context: Context) {}
}

private class QRCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var hasReported = false

    override func viewDidLoad() {
        super.viewDidLoad()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if let preview = view.layer.sublayers?.first as? AVCaptureVideoPreviewLayer {
            preview.frame = view.bounds
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        session.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasReported,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              object.type == .qr,
              let value = object.stringValue else { return }
        hasReported = true
        onCode?(value)
    }
}
#endif
