// CineCam — pro camera engine (AVFoundation + Vision face tracking + Core Image filters)
import AVFoundation
import Vision
import CoreImage
import UIKit
import Photos

enum CamMode { case photo, video }
enum CamResolution: String, CaseIterable { case r4K = "4K", r1080 = "1080p", r720 = "720p" }
enum CamFPS: Int, CaseIterable { case fps24 = 24, fps30 = 30, fps60 = 60 }

struct CamFilter: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let ciFilter: String? // Core Image filter name, nil = none
    let intensity: Double
    static let all: [CamFilter] = [
        CamFilter(name: "None", ciFilter: nil, intensity: 1),
        CamFilter(name: "Vivid", ciFilter: "CIColorControls", intensity: 1),
        CamFilter(name: "Noir", ciFilter: "CIPhotoEffectNoir", intensity: 1),
        CamFilter(name: "Mono", ciFilter: "CIPhotoEffectMono", intensity: 1),
        CamFilter(name: "Warm", ciFilter: "CITemperatureAndTint", intensity: 1),
        CamFilter(name: "Cool", ciFilter: "CITemperatureAndTint", intensity: 1),
        CamFilter(name: "Fade", ciFilter: "CIPhotoEffectFade", intensity: 1),
        CamFilter(name: "Chrome", ciFilter: "CIPhotoEffectChrome", intensity: 1),
        CamFilter(name: "Instant", ciFilter: "CIPhotoEffectInstant", intensity: 1),
        CamFilter(name: "Process", ciFilter: "CIPhotoEffectProcess", intensity: 1),
        CamFilter(name: "Tonal", ciFilter: "CIPhotoEffectTonal", intensity: 1),
        CamFilter(name: "Transfer", ciFilter: "CIPhotoEffectTransfer", intensity: 1),
    ]
}

final class CameraModel: NSObject, ObservableObject {
    @Published var session = AVCaptureSession()
    @Published var isRecording = false
    @Published var mode: CamMode = .video
    @Published var resolution: CamResolution = .r4K
    @Published var fps: CamFPS = .fps60
    @Published var filter: CamFilter = .all[0]
    @Published var filterIntensity: Double = 1.0
    @Published var iso: Float = 0          // 0 = auto
    @Published var shutter: Double = 0     // seconds, 0 = auto
    @Published var whiteBalance: Double = 0 // Kelvin, 0 = auto
    @Published var exposureBias: Float = 0
    @Published var focusLocked = false
    @Published var trackedFace: CGRect?    // normalized rect of tracked face
    @Published var trackFace = true
    @Published var showGrid = true
    @Published var stabilization = true
    @Published var lastPhoto: UIImage?
    @Published var recordTime: TimeInterval = 0
    @Published var status = "Starting camera…"

    private var videoDevice: AVCaptureDevice?
    private var photoOutput = AVCapturePhotoOutput()
    private var movieOutput = AVCaptureMovieFileOutput()
    private var videoDataOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var recordTimer: Timer?
    private var recordStart: Date?
    private var outputURL: URL?
    private let sessionQueue = DispatchQueue(label: "cinecam.session")
    private let videoQueue = DispatchQueue(label: "cinecam.video")
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var lastFaceCheck = Date.distantPast
    private let ciContext = CIContext()

    var minISO: Float { videoDevice?.activeFormat.minISO ?? 25 }
    var maxISO: Float { videoDevice?.activeFormat.maxISO ?? 2000 }
    var minShutter: Double { 1.0 / 8000 }
    var maxShutter: Double { 1.0 / 24 }

    // MARK: - Setup
    func setup() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd4K3840x2160
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
                DispatchQueue.main.async { self.status = "No camera found." }
                return
            }
            self.videoDevice = device
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input) }
                self.videoInput = input
            } catch { DispatchQueue.main.async { self.status = "Camera error: \(error.localizedDescription)" } }
            if self.session.canAddOutput(self.photoOutput) { self.session.addOutput(self.photoOutput) }
            if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
            // Frame tap for Vision face tracking
            self.videoDataOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            if self.session.canAddOutput(self.videoDataOutput) { self.session.addOutput(self.videoDataOutput) }
            self.session.commitConfiguration()
            self.applyFormat()
            self.session.startRunning()
            DispatchQueue.main.async { self.status = "Ready — 4K 60" }
        }
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        previewLayer = layer
        layer.session = session
        layer.videoGravity = .resizeAspectFill
    }

    // MARK: - Format (resolution + fps)
    func applyFormat() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            self.session.beginConfiguration()
            switch self.resolution {
            case .r4K: self.session.sessionPreset = .hd4K3840x2160
            case .r1080: self.session.sessionPreset = .hd1920x1080
            case .r720: self.session.sessionPreset = .hd1280x720
            }
            do {
                try device.lockForConfiguration()
                // Pick the best format for the requested fps
                let target = Double(self.fps.rawValue)
                if let fmt = device.formats.filter({ f in
                    let dims = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                    let wantW: Int32 = self.resolution == .r4K ? 3840 : (self.resolution == .r1080 ? 1920 : 1280)
                    return dims.width == wantW && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= target && $0.maxFrameRate >= target }
                }).max(by: { a, b in
                    CMVideoFormatDescriptionGetDimensions(a.formatDescription).width < CMVideoFormatDescriptionGetDimensions(b.formatDescription).width
                }) {
                    device.activeFormat = fmt
                }
                let dur = CMTime(value: 1, timescale: CMTimeScale(target))
                device.activeVideoMinFrameDuration = dur
                device.activeVideoMaxFrameDuration = dur
                device.unlockForConfiguration()
            } catch {}
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.status = "Ready — \(self.resolution.rawValue) \(self.fps.rawValue)" }
        }
    }

    // MARK: - Manual controls
    func applyManual() {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if self.iso > 0 || self.shutter > 0 {
                    let isoVal = self.iso > 0 ? self.iso : device.iso
                    let dur = self.shutter > 0 ? CMTime(seconds: self.shutter, preferredTimescale: 1000) : device.exposureDuration
                    device.setExposureModeCustom(duration: dur, iso: isoVal, completionHandler: nil)
                } else {
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
                if self.whiteBalance > 0 {
                    let gains = device.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(self.whiteBalance), tint: 0))
                    device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                } else {
                    if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
                }
                device.setExposureTargetBias(self.exposureBias, completionHandler: nil)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func setISO(_ v: Float) { iso = v; applyManual() }
    func setShutter(_ v: Double) { shutter = v; applyManual() }
    func setWB(_ k: Double) { whiteBalance = k; applyManual() }
    func setExposureBias(_ v: Float) { exposureBias = v; applyManual() }
    func setAuto() { iso = 0; shutter = 0; whiteBalance = 0; applyManual() }

    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoDevice, let layer = self.previewLayer else { return }
            let p = layer.captureDevicePointConverted(fromLayerPoint: point)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = p
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = p
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func lockFocus(_ locked: Bool) {
        focusLocked = locked
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.focusMode = locked ? .locked : .continuousAutoFocus
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func switchCamera() {
        sessionQueue.async {
            guard let current = self.videoInput else { return }
            let newPos: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPos) else { return }
            self.session.beginConfiguration()
            self.session.removeInput(current)
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) { self.session.addInput(input); self.videoInput = input; self.videoDevice = device }
            } catch {}
            self.session.commitConfiguration()
            self.applyFormat()
        }
    }

    // MARK: - Photo
    func takePhoto() {
        let settings = AVCapturePhotoSettings()
        settings.flashMode = .off
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Video
    func toggleRecord() { isRecording ? stopRecord() : startRecord() }

    func startRecord() {
        guard !movieOutput.isRecording else { return }
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("cinecam-\(Int(Date().timeIntervalSince1970)).mov")
        outputURL = url
        if movieOutput.isRecording { return }
        if let conn = movieOutput.connection(with: .video) {
            conn.videoOrientation = .portrait
            conn.preferredVideoStabilizationMode = stabilization ? .cinematicExtended : .off
        }
        movieOutput.startRecording(to: url, recordingDelegate: self)
        recordStart = Date()
        isRecording = true
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let s = self.recordStart else { return }
            self.recordTime = Date().timeIntervalSince(s)
        }
    }

    func stopRecord() {
        movieOutput.stopRecording()
        isRecording = false
        recordTimer?.invalidate()
        recordTimer = nil
        recordTime = 0
    }

    // MARK: - Face tracking (Vision)
    func checkFaces(in pixelBuffer: CVPixelBuffer) {
        guard trackFace, Date().timeIntervalSince(lastFaceCheck) > 0.25 else { return }
        lastFaceCheck = Date()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest])
            if let face = faceRequest.results?.first {
                DispatchQueue.main.async { self.trackedFace = face.boundingBox }
                // Keep focus/exposure on the face center
                let c = CGPoint(x: face.boundingBox.midX, y: 1 - face.boundingBox.midY)
                sessionQueue.async {
                    guard let device = self.videoDevice else { return }
                    do {
                        try device.lockForConfiguration()
                        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = c }
                        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = c }
                        device.unlockForConfiguration()
                    } catch {}
                }
            } else {
                DispatchQueue.main.async { self.trackedFace = nil }
            }
        } catch {}
    }

    // MARK: - Filters (applied to captured photos)
    func applyFilter(to image: UIImage) -> UIImage {
        guard let name = filter.ciFilter else { return image }
        guard let ci = CIImage(image: image) else { return image }
        var out = ci
        if name == "CIColorControls" {
            let f = CIFilter(name: name)!
            f.setValue(ci, forKey: kCIInputImageKey)
            f.setValue(1.15, forKey: kCIInputSaturationKey)
            f.setValue(1.08, forKey: kCIInputContrastKey)
            out = f.outputImage ?? ci
        } else if name == "CITemperatureAndTint" {
            let f = CIFilter(name: name)!
            f.setValue(ci, forKey: kCIInputImageKey)
            let temp: CGFloat = filter.name == "Warm" ? 6500 : 3500
            f.setValue(CIVector(x: temp, y: 0), forKey: "inputNeutral")
            f.setValue(CIVector(x: 6500, y: 0), forKey: "inputTargetNeutral")
            out = f.outputImage ?? ci
        } else {
            let f = CIFilter(name: name)!
            f.setValue(ci, forKey: kCIInputImageKey)
            out = f.outputImage ?? ci
        }
        // Sharpen / AI-ish enhance pass
        if let sharp = CIFilter(name: "CISharpenLuminance") {
            sharp.setValue(out, forKey: kCIInputImageKey)
            sharp.setValue(0.4 * filterIntensity, forKey: kCIInputSharpnessKey)
            out = sharp.outputImage ?? out
        }
        guard let cg = ciContext.createCGImage(out, from: out.extent) else { return image }
        return UIImage(cgImage: cg, scale: image.scale, orientation: image.imageOrientation)
    }

    func saveToLibrary(image: UIImage) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            })
        }
    }

    func saveVideoToLibrary(url: URL) {
        PHPhotoLibrary.requestAuthorization { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            })
        }
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        checkFaces(in: pb)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), var img = UIImage(data: data) else { return }
        img = applyFilter(to: img)
        DispatchQueue.main.async { self.lastPhoto = img }
        saveToLibrary(image: img)
    }
}

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if error == nil { saveVideoToLibrary(url: outputFileURL) }
    }
}
