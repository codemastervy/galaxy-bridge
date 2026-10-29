import AVFoundation
import AVKit
import Photos
import SwiftUI

/// Camera with a shutter the watch can press. Photos go to the library with add-only access.
@MainActor
final class Camera: NSObject, ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var message: String?
    @Published private(set) var captureCount = 0

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Camera access is off. Turn it on in Settings → Galaxy Bridge."
            return
        }
        let session = session, output = output
        let configured: Bool = await withCheckedContinuation { done in
            queue.async {
                if session.inputs.isEmpty {
                    session.beginConfiguration()
                    session.sessionPreset = .photo
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                          let input = try? AVCaptureDeviceInput(device: device),
                          session.canAddInput(input), session.canAddOutput(output) else {
                        session.commitConfiguration()
                        done.resume(returning: false)
                        return
                    }
                    session.addInput(input)
                    session.addOutput(output)
                    session.commitConfiguration()
                }
                session.startRunning()
                done.resume(returning: true)
            }
        }
        ready = configured
        if !configured { message = "Couldn't open the camera" }
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
        ready = false
    }

    func capture() {
        guard ready else { return }
        captureCount += 1
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    private func save(_ data: Data) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow adding photos in Settings → Galaxy Bridge"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            message = "Saved to Photos"
        } catch {
            message = "Couldn't save photo"
        }
    }
}

extension Camera: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            guard error == nil, let data else {
                message = "Photo failed"
                return
            }
            await save(data)
        }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Called for volume-button presses, including the watch acting as a Bluetooth remote.
    var onHardwareShutter: () -> Void = {}

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if #available(iOS 17.2, *) {
            let action = onHardwareShutter
            view.addInteraction(AVCaptureEventInteraction { event in
                if event.phase == .ended { action() }
            })
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
