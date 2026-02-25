// ============================================================
// SPLING — FULL STACK v5
// QRScanner.swift
// Contains: QRPayloadParser + QRScannerViewModel + QRScannerView
// ADD this file to your Xcode target.
// Also add NSCameraUsageDescription to Info.plist:
// "Spling uses the camera to scan vendor QR codes."
// ============================================================
import SwiftUI
import AVFoundation

// ─────────────────────────────────────────────────────────────
// MARK: - QR Payload Parser
// ─────────────────────────────────────────────────────────────

enum QRPayloadParser {
    /// Parses a raw QR string into a VendorContextInput.
    /// Supports two formats:
    ///   1. Plain URL:  "https://timhortons.ca/menu"
    ///   2. JSON:  {"schemaVersion":"1.0","vendorWebsiteURL":"..."}
    static func parse(_ raw: String) throws -> VendorContextInput {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QRParseError.emptyPayload }

        // Attempt JSON decode first
        if let data = trimmed.data(using: .utf8),
           let payload = try? JSONDecoder().decode(QRVendorPayload.self, from: data) {
            return try buildInput(from: payload)
        }

        // Fallback: treat as plain URL
        let normalised = normaliseURL(trimmed)
        guard let url = URL(string: normalised) else {
            throw QRParseError.invalidURL(trimmed)
        }
        return VendorContextInput(
            vendorID: nil,
            vendorName: nil,
            vendorURL: url,
            terminalType: nil,
            currency: nil
        )
    }

    // MARK: - Private helpers

    private static func buildInput(from payload: QRVendorPayload) throws -> VendorContextInput {
        let supportedVersions = ["1.0"]
        if !supportedVersions.contains(payload.schemaVersion) {
            throw QRParseError.unsupportedSchemaVersion(payload.schemaVersion)
        }
        let normalised = normaliseURL(payload.vendorWebsiteURL)
        guard let url = URL(string: normalised) else {
            throw QRParseError.invalidURL(payload.vendorWebsiteURL)
        }
        return VendorContextInput(
            vendorID: payload.vendorID,
            vendorName: payload.vendorName,
            vendorURL: url,
            terminalType: mapTerminalType(payload.defaultTerminalType),
            currency: payload.currency
        )
    }

    /// Adds https:// if missing, strips trailing slash, lowercases.
    /// Must match AIMenuService.normalise() for cache key consistency.
    static func normaliseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") { s = "https://" + s }
        if s.hasSuffix("/") { s = String(s.dropLast()) }
        return s.lowercased()
    }

    private static func mapTerminalType(_ raw: String?) -> TerminalType? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "drive-through", "drivethrough", "speaker", "speakerbox":
            return .speakerBox
        case "intercom":
            return .intercom
        case "counter", "frontdesk", "front-desk":
            return .frontDesk
        case "kiosk":
            return .kiosk
        default:
            return nil
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - QR Scanner ViewModel
// ─────────────────────────────────────────────────────────────

@MainActor
final class QRScannerViewModel: NSObject, ObservableObject {
    @Published var scannedPayload: String?
    @Published var scanError: QRScanError?
    @Published var isScanning: Bool = false
    @Published var isProcessing: Bool = false
    @Published var permissionDenied: Bool = false

    // NOTE: Made internal (not private) so QRCameraPreview can read it
    var captureSession: AVCaptureSession?

    private var hasScanned = false

    enum QRScanError: LocalizedError {
        case cameraUnavailable
        case permissionDenied
        case sessionFailed(String)

        var errorDescription: String? {
            switch self {
            case .cameraUnavailable: return "Camera is not available on this device."
            case .permissionDenied:  return "Camera access denied. Enable it in Settings → Privacy → Camera → Spling."
            case .sessionFailed(let m): return "Camera error: \(m)"
            }
        }
    }

    // MARK: - Lifecycle

    func checkPermissionAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    if granted { self?.configureAndStart() }
                    else { self?.permissionDenied = true }
                }
            }
        case .denied, .restricted:
            permissionDenied = true
        @unknown default:
            permissionDenied = true
        }
    }

    func stop() {
        captureSession?.stopRunning()
        isScanning = false
    }

    func reset() {
        scannedPayload = nil
        scanError = nil
        isProcessing = false
        hasScanned = false
    }

    // MARK: - Private

    private func configureAndStart() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video) else {
            scanError = .cameraUnavailable; return
        }
        do {
            let input  = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureMetadataOutput()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                scanError = .sessionFailed("Cannot configure camera session."); return
            }
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .global(qos: .userInitiated))
            output.metadataObjectTypes = [.qr]
            captureSession = session
            DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
            isScanning = true
        } catch {
            scanError = .sessionFailed(error.localizedDescription)
        }
    }
}

// MARK: - AVCaptureMetadataOutputObjectsDelegate

extension QRScannerViewModel: AVCaptureMetadataOutputObjectsDelegate {
    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let string = obj.stringValue else { return }

        Task { @MainActor [weak self] in
            guard let self, !self.hasScanned else { return }
            self.hasScanned = true
            self.isProcessing = true
            self.captureSession?.stopRunning()
            self.isScanning = false
            HapticManager.shared.notification(.success)
            self.scannedPayload = string
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Camera Preview (UIViewRepresentable)
// ─────────────────────────────────────────────────────────────

struct QRCameraPreview: UIViewRepresentable {
    let session: AVCaptureSession?

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        if let session {
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            context.coordinator.previewLayer = layer
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - Corner Brackets (viewfinder shape)
// ─────────────────────────────────────────────────────────────

struct CornerBrackets: Shape {
    var cornerLength: CGFloat = 28
    var lineWidth: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + cornerLength),
             CGPoint(x: rect.minX, y: rect.minY),
             CGPoint(x: rect.minX + cornerLength, y: rect.minY)),
            (CGPoint(x: rect.maxX - cornerLength, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY + cornerLength)),
            (CGPoint(x: rect.maxX, y: rect.maxY - cornerLength),
             CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.maxX - cornerLength, y: rect.maxY)),
            (CGPoint(x: rect.minX + cornerLength, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.maxY - cornerLength))
        ]
        for (start, corner, end) in corners {
            path.move(to: start)
            path.addLine(to: corner)
            path.addLine(to: end)
        }
        return path
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - QR Scanner View
// ─────────────────────────────────────────────────────────────

struct QRScannerView: View {
    let onScan: (String) -> Void
    let onDismiss: () -> Void

    @StateObject private var vm = QRScannerViewModel()
    @EnvironmentObject var accessibility: AccessibilityViewModel
    @State private var scanLineOffset: CGFloat = -130

    var body: some View {
        ZStack {
            // Camera feed
            QRCameraPreview(session: vm.captureSession)
                .ignoresSafeArea()

            // Dim overlay
            Color.black.opacity(0.45)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Text("Scan Vendor QR Code")
                    .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Point camera at the QR code near the drive-through terminal")
                    .font(.system(size: accessibility.dynamicFontSize - 3))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Viewfinder
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.blue, lineWidth: 2)
                        .frame(width: 260, height: 260)

                    CornerBrackets()
                        .stroke(Color.blue, lineWidth: 5)
                        .frame(width: 260, height: 260)

                    if vm.isScanning {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, .blue.opacity(0.6), .clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: 240, height: 2)
                            .offset(y: scanLineOffset)
                            .onAppear {
                                withAnimation(.linear(duration: 2).repeatForever(autoreverses: true)) {
                                    scanLineOffset = 130
                                }
                            }
                    }

                    if vm.isProcessing {
                        ProgressView()
                            .scaleEffect(1.4)
                            .tint(.white)
                    }
                }

                if let error = vm.scanError {
                    Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: accessibility.dynamicFontSize - 2))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                Button {
                    HapticManager.shared.impact(.light)
                    vm.stop()
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .font(.system(size: accessibility.dynamicFontSize, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 44, minHeight: 44)
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(.white.opacity(0.15), in: Capsule())
                }
                .accessibilityLabel("Cancel QR scanning")
                .padding(.bottom, 48)
            }

            if vm.permissionDenied {
                cameraPermissionDeniedView
            }
        }
        .statusBarHidden(true)
        .onAppear {
            vm.checkPermissionAndStart()
            accessibility.announceForVoiceOver("QR scanner is active. Point camera at vendor QR code.")
        }
        .onDisappear { vm.stop() }
        .onChange(of: vm.scannedPayload) { _, payload in
            guard let payload else { return }
            onScan(payload)
        }
    }

    // MARK: - Permission Denied View

    private var cameraPermissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)

            Text("Camera Access Required")
                .font(.system(size: accessibility.dynamicFontSize + 2, weight: .bold))
                .foregroundStyle(.white)

            Text("To scan vendor QR codes, please enable camera access:\nSettings → Privacy → Camera → Spling")
                .font(.system(size: accessibility.dynamicFontSize - 2))
                .foregroundStyle(.white.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.yellow)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.9))
        .ignoresSafeArea()
    }
}
