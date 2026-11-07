// CineCam — pro camera UI: HUD, manual controls, filters, face tracking overlay
import SwiftUI
import AVFoundation

@main
struct CineCamApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct CameraPreview: UIViewRepresentable {
    let model: CameraModel
    let onTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer()
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        model.setPreviewLayer(layer)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        if let layer = uiView.layer.sublayers?.compactMap({ $0 as? AVCaptureVideoPreviewLayer }).first {
            layer.frame = uiView.bounds
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    class Coordinator: NSObject {
        var view: UIView?
        let onTap: (CGPoint) -> Void
        init(onTap: @escaping (CGPoint) -> Void) { self.onTap = onTap }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = view else { return }
            onTap(g.location(in: v))
        }
    }
}

struct ContentView: View {
    @StateObject private var model = CameraModel()
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var tapPoint: CGPoint?
    @State private var tapTime = Date()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            GeometryReader { geo in
                ZStack {
                    CameraPreview(model: model) { pt in
                        tapPoint = pt
                        tapTime = Date()
                        model.focus(at: pt)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { tapPoint = nil }
                    }
                    .ignoresSafeArea()

                    // Face tracking box
                    if let face = model.trackedFace, model.trackFace {
                        let r = faceRect(face, in: geo.size)
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.green, lineWidth: 2)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }

                    // Tap-to-focus indicator
                    if let pt = tapPoint {
                        Circle()
                            .stroke(Color.yellow, lineWidth: 2)
                            .frame(width: 70, height: 70)
                            .position(pt)
                    }

                    // Rule-of-thirds grid
                    if model.showGrid {
                        GridOverlay()
                    }

                    VStack {
                        // Top HUD
                        HStack(spacing: 14) {
                            hudChip("\(model.resolution.rawValue)")
                            hudChip("\(model.fps.rawValue) fps")
                            hudChip(model.isRecording ? "● REC \(timeString(model.recordTime))" : "READY")
                                .foregroundColor(model.isRecording ? .red : .white)
                            Spacer()
                            Button(action: { model.switchCamera() }) {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .foregroundColor(.white).font(.title3)
                            }
                            Button(action: { showSettings.toggle() }) {
                                Image(systemName: "slider.horizontal.3")
                                    .foregroundColor(.white).font(.title3)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)

                        Spacer()

                        // Filter strip
                        if showFilters {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(CamFilter.all) { f in
                                        Button(action: { model.filter = f }) {
                                            Text(f.name)
                                                .font(.caption).bold()
                                                .padding(.horizontal, 12).padding(.vertical, 8)
                                                .background(model.filter == f ? Color.white : Color.white.opacity(0.15))
                                                .foregroundColor(model.filter == f ? .black : .white)
                                                .cornerRadius(16)
                                        }
                                    }
                                }
                                .padding(.horizontal)
                            }
                            .padding(.bottom, 6)
                        }

                        // Manual controls
                        VStack(spacing: 8) {
                            controlRow("ISO", value: model.iso > 0 ? "\(Int(model.iso))" : "AUTO") {
                                Slider(value: Binding(get: { Double(model.iso) }, set: { model.setISO(Float($0)) }), in: 25...2000, step: 1)
                            }
                            controlRow("Shutter", value: model.shutter > 0 ? "1/\(Int(1 / model.shutter))" : "AUTO") {
                                Slider(value: Binding(get: { model.shutter > 0 ? 1 / model.shutter : 60 }, set: { model.setShutter(1 / $0) }), in: 24...8000, step: 1)
                            }
                            controlRow("WB", value: model.whiteBalance > 0 ? "\(Int(model.whiteBalance))K" : "AUTO") {
                                Slider(value: Binding(get: { model.whiteBalance > 0 ? model.whiteBalance : 5600 }, set: { model.setWB($0) }), in: 2500...9000, step: 100)
                            }
                            HStack(spacing: 10) {
                                Button("AUTO") { model.setAuto() }
                                    .buttonStyle(.bordered)
                                Button(model.focusLocked ? "Focus: LOCKED" : "Focus: AUTO") { model.lockFocus(!model.focusLocked) }
                                    .buttonStyle(.bordered)
                                Button("Filters") { showFilters.toggle() }
                                    .buttonStyle(.bordered)
                                Spacer()
                                Text("Filter: \(model.filter.name)")
                                    .font(.caption).foregroundColor(.white.opacity(0.7))
                            }
                            .tint(.white)
                            .font(.caption)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 6)

                        // Bottom bar: mode + shutter
                        HStack(spacing: 24) {
                            Button(action: { model.mode = .photo }) {
                                Text("PHOTO").font(.caption).bold()
                                    .foregroundColor(model.mode == .photo ? .white : .white.opacity(0.5))
                            }
                            Button(action: {
                                if model.mode == .photo { model.takePhoto() } else { model.toggleRecord() }
                            }) {
                                ZStack {
                                    Circle().stroke(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                                    if model.mode == .video && model.isRecording {
                                        RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 32, height: 32)
                                    } else {
                                        Circle().fill(model.mode == .video ? Color.red : Color.white).frame(width: 58, height: 58)
                                    }
                                }
                            }
                            Button(action: { model.mode = .video }) {
                                Text("VIDEO").font(.caption).bold()
                                    .foregroundColor(model.mode == .video ? .white : .white.opacity(0.5))
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
        }
        .onAppear { model.setup() }
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
        }
        .statusBarHidden()
    }

    func faceRect(_ f: CGRect, in size: CGSize) -> CGRect {
        // Vision rects are bottom-left origin; preview is aspect-fill.
        CGRect(x: f.minX * size.width, y: (1 - f.maxY) * size.height,
               width: f.width * size.width, height: f.height * size.height)
    }
    func hudChip(_ t: String) -> some View {
        Text(t).font(.caption).bold().padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.55)).cornerRadius(6)
    }
    func controlRow<Content: View>(_ label: String, value: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.caption).bold().frame(width: 52, alignment: .leading)
            content()
            Text(value).font(.caption).frame(width: 52, alignment: .trailing)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.black.opacity(0.5)).cornerRadius(8)
    }
    func timeString(_ t: TimeInterval) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }
}

struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                let w = geo.size.width, h = geo.size.height
                p.move(to: CGPoint(x: w / 3, y: 0)); p.addLine(to: CGPoint(x: w / 3, y: h))
                p.move(to: CGPoint(x: 2 * w / 3, y: 0)); p.addLine(to: CGPoint(x: 2 * w / 3, y: h))
                p.move(to: CGPoint(x: 0, y: h / 3)); p.addLine(to: CGPoint(x: w, y: h / 3))
                p.move(to: CGPoint(x: 0, y: 2 * h / 3)); p.addLine(to: CGPoint(x: w, y: 2 * h / 3))
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: CameraModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationView {
            Form {
                Section("Video") {
                    Picker("Resolution", selection: $model.resolution) {
                        ForEach(CamResolution.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .onChange(of: model.resolution) { _ in model.applyFormat() }
                    Picker("Frame rate", selection: $model.fps) {
                        ForEach(CamFPS.allCases, id: \.self) { Text("\($0.rawValue) fps") }
                    }
                    .onChange(of: model.fps) { _ in model.applyFormat() }
                    Toggle("Video stabilization", isOn: $model.stabilization)
                }
                Section("Tracking & display") {
                    Toggle("Face tracking (motion)", isOn: $model.trackFace)
                    Toggle("Rule-of-thirds grid", isOn: $model.showGrid)
                }
                Section("Filter") {
                    Picker("Look", selection: $model.filter) {
                        ForEach(CamFilter.all) { Text($0.name) }
                    }
                    Slider(value: $model.filterIntensity, in: 0...1, step: 0.05) {
                        Text("Intensity")
                    }
                }
                Section("Exposure") {
                    HStack {
                        Text("Bias")
                        Slider(value: Binding(get: { Double(model.exposureBias) }, set: { model.setExposureBias(Float($0)) }), in: -2...2, step: 0.1)
                        Text(String(format: "%+.1f", model.exposureBias))
                    }
                    Button("Reset all to AUTO") { model.setAuto() }
                }
                Section {
                    Text("4K 60fps needs iPhone 12 or newer. Face tracking uses on-device Vision — nothing leaves your phone.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .navigationTitle("CineCam Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
