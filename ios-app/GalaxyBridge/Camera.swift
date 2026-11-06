import AVFoundation
import CoreImage
import AVKit
import Photos
import SwiftUI

/// Camera with a shutter the watch can press. Photos go to the library with add-only access.
@MainActor
final class Camera: NSObject, ObservableObject {
    @Published private(set) var ready = false
    @Published private(set) var message: String?
    @Published private(set) var captureCount = 0
    @Published private(set) var position: AVCaptureDevice.Position = .back
    /// Self-timer for shots: 0, 3 or 10 seconds.
    @Published private(set) var timerSeconds = 0
    @Published private(set) var countdown = 0
    /// The watch is showing the camera page and wants preview frames.
    var streamToWatch = false
    /// Small JPEG preview frames for the watch, about two a second.
    var onFrame: ((Data) -> Void)?
    var onStateChange: (() -> Void)?
    private let video = AVCaptureVideoDataOutput()
    private let frameQueue = DispatchQueue(label: "camera.frames")
    private nonisolated(unsafe) var lastFrame = Date.distantPast
    private nonisolated(unsafe) var wantFrames = false
    private let ciContext = CIContext()

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "camera.session")

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Camera access is off. Turn it on in Settings → Wear OS Bridge."
            return
        }
        let session = session, output = output, video = video
        video.setSampleBufferDelegate(self, queue: frameQueue)
        video.alwaysDiscardsLateVideoFrames = true
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
                    if session.canAddOutput(video) { session.addOutput(video) }
                    session.commitConfiguration()
                }
                session.startRunning()
                done.resume(returning: true)
            }
        }
        ready = configured
        if !configured { message = "Couldn't open the camera" }
        onStateChange?()
    }

    func stop() {
        let session = session
        queue.async { session.stopRunning() }
        ready = false
        onStateChange?()
    }

    func capture() {
        guard ready, countdown == 0 else { return }
        guard timerSeconds > 0 else { return shootNow() }
        countdown = timerSeconds
        Task {
            while countdown > 0 {
                try? await Task.sleep(for: .seconds(1))
                countdown -= 1
            }
            shootNow()
        }
    }

    private func shootNow() {
        guard ready else { return }
        captureCount += 1
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : timerSeconds == 3 ? 10 : 0
        onStateChange?()
    }

    func flip() {
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        let session = session
        queue.async {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: next),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            for old in session.inputs { session.removeInput(old) }
            if session.canAddInput(input) { session.addInput(input) }
            session.commitConfiguration()
            Task { @MainActor in self.position = next; self.onStateChange?() }
        }
    }

    /// Kept in step with streamToWatch on the main actor, read on the frame queue.
    func updateStreaming() { wantFrames = streamToWatch && ready }

    private func save(_ data: Data) async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            message = "Allow adding photos in Settings → Wear OS Bridge"
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

extension Camera: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard wantFrames, Date().timeIntervalSince(lastFrame) > 0.5,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = Date()
        var image = CIImage(cvPixelBuffer: pixels).oriented(.right)
        let scale = 240 / max(image.extent.width, image.extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(image, from: image.extent),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.45) else { return }
        Task { @MainActor in self.onFrame?(jpeg) }
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
