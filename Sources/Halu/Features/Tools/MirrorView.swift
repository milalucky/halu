import AVFoundation
import SwiftUI

/// The camera, mirrored, for a look before a call. The camera runs only while this is on screen.
struct MirrorView: View {
    let onClose: () -> Void
    @State private var allowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var denied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if allowed {
                    CameraPreview()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    EmptyState(icon: "web.camera", title: denied ? "Camera access is off" : "Checking the camera",
                               subtitle: denied ? "Turn on Halu in System Settings → Privacy & Security → Camera." : "Allow the camera to see yourself before a call.")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            IconButton(icon: "xmark", help: "Close", size: 10, action: onClose)
                .padding(8)
                .background(Circle().fill(.black.opacity(0.5)))
                .padding(10)
        }
        .onAppear {
            guard !allowed else { return }
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    withAnimation { allowed = granted }
                    denied = !granted
                }
            }
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    final class Coordinator {
        let session = AVCaptureSession()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let session = context.coordinator.session
        session.sessionPreset = .high
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.connection?.automaticallyAdjustsVideoMirroring = false
        preview.connection?.isVideoMirrored = true
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = CALayer()
        view.layer?.addSublayer(preview)
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }
}
