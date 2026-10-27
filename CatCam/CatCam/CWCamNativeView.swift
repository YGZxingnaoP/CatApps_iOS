import SwiftUI
import AVFoundation

/// 手机端 `.cam` 的原生等价界面：整屏相机 + 三枚按钮球 + 气泡 + 顶部模式/音量
struct CWCamNativeView: View {
    @EnvironmentObject private var store: CWStore
    @ObservedObject private var live = CWLive.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var draft = ""
    @State private var showInput = false
    @State private var booted = false
    @State private var showIdentity = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if live.cameraOn {
                CWCameraPreview(camera: live.camera)
                    .ignoresSafeArea()
            } else {
                placeholder
            }

            VStack(spacing: 10) {
                header
                Spacer(minLength: 0)
                footer
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showInput { inputBar }
        }
        .onAppear(perform: boot)
        .onDisappear { live.suspendVideo() }
        .onChange(of: store.config) { value in
            // 设置页改完 PC 地址/HTTPS 后，立刻重配并补连（不依赖“重新进相机页”）
            live.configure(value)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                live.foregrounded()
            } else {
                live.suspendVideo()
            }
        }
        .sheet(isPresented: $showIdentity) {
            CWIdentitySheet(current: store.config.meowID) { value in
                store.config.meowID = value
                live.applyIdentity(value)
            }
        }
    }

    // MARK: 顶部

    private var header: some View {
        VStack(spacing: 8) {
            // 中间的模式胶囊单独居中：两侧元素宽度变化不影响它
            ZStack {
                HStack {
                    Spacer(minLength: 0)
                    modePill
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    nameTag
                    Spacer(minLength: 0)
                    iconButton(system: "arrow.triangle.2.circlepath.camera",
                               title: "切换前后摄像头") {
                        live.flipCamera()
                    }
                    .disabled(!live.cameraOn)
                    .opacity(live.cameraOn ? 1 : 0.4)
                }
            }
            .frame(minHeight: 34)
            HStack(spacing: 10) {
                Button {
                    live.toggleMute()
                } label: {
                    Image(systemName: live.muted || live.volume <= 0.001
                          ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
                        .background(Color.black.opacity(0.35))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Slider(value: Binding(get: { live.volume }, set: { live.setVolume($0) }), in: 0...1)
                    .tint(CWTheme.pink)
                Text(live.fps > 0 ? String(format: "%.0ffps", live.fps) : "")
                    .font(.caption2.monospacedDigit())
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 42, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.28))
            .clipShape(Capsule())
        }
    }

    private var nameTag: some View {
        Button {
            showIdentity = true
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(live.connected ? CWTheme.mint : Color.orange)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(live.nameLabel)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if !live.uidLabel.isEmpty {
                        Text(live.uidLabel)
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.35))
            .clipShape(Capsule())
            .frame(maxWidth: 150, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("切换 MeowID")
    }

    private var modePill: some View {
        Button {
            live.toggleMode()
            flashNote("正在切换模式…")
        } label: {
            Text(live.mode == "call" ? "通话·全部" : "聊天·仅我")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(CWTheme.pink.opacity(0.85))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func iconButton(system: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.35))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 底部

    private var footer: some View {
        VStack(spacing: 8) {
            if !live.aiText.isEmpty {
                Button {
                    live.dismissBubble()
                } label: {
                    Text(live.aiText)
                        .font(.callout)
                        .foregroundColor(CWTheme.ink)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.94))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if !live.hint.isEmpty {
                Text(live.hint)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.35))
                    .clipShape(Capsule())
            }
            if !live.userLine.isEmpty {
                Text(live.userLine)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(2)
            }
            HStack(spacing: 34) {
                ball(system: live.cameraOn ? "video.fill" : "video",
                     on: live.cameraOn, label: "摄像头") {
                    live.toggleCamera()
                }
                ball(system: live.micOn ? "mic.fill" : "mic",
                     on: live.micOn, label: "麦克风") {
                    live.toggleMic()
                }
                ball(system: "text.bubble.fill", on: showInput, label: "消息") {
                    showInput.toggle()
                    if showInput {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            inputFocused = true
                        }
                    } else {
                        inputFocused = false
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    private func ball(system: String, on: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 62, height: 62)
                .background(on ? CWTheme.pink.opacity(0.92) : Color.white.opacity(0.18))
                .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("说点什么…", text: $draft)
                .textFieldStyle(.plain)
                .focused($inputFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
                .clipShape(Capsule())
            Button(action: send) {
                Image(systemName: "paperplane.fill")
                    .foregroundColor(.white)
                    .frame(width: 40, height: 40)
                    .background(CWTheme.pink)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.metering.unknown")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(.white.opacity(0.6))
            Text("摄像头未开启")
                .font(.headline)
                .foregroundColor(.white.opacity(0.85))
            Text("点下方相机球开；开麦后切后台/锁屏仍会继续录音，视频只在界面内推。")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.55))
                .padding(.horizontal, 36)
            if store.config.camHost == nil {
                Text("先去「设置」填 PC 地址")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(CWTheme.pink)
            }
        }
    }

    // MARK: 动作

    private func boot() {
        if !booted {
            booted = true
            live.logSink = { text in
                DispatchQueue.main.async {
                    store.log(text)
                }
            }
            live.configure(store.config)
            live.start()
            return
        }
        // 再次进入相机页：重新应用一次配置，避免“设置改完没生效”
        live.configure(store.config)
        live.resumeVideo()
    }

    private func send() {
        let text = draft
        draft = ""
        live.sendChat(text)
        showInput = false
        inputFocused = false
    }

    private func flashNote(_ text: String) {
        live.sendLocalHint(text)
    }
}

/// 相机预览（预览层自带旋转）
struct CWCameraPreview: UIViewRepresentable {
    let camera: CWCamera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.preview.session = camera.session
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.preview.session !== camera.session {
            uiView.preview.session = camera.session
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            preview.videoGravity = .resizeAspectFill
            if let connection = preview.connection {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(90) {
                        connection.videoRotationAngle = 90
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
        }
    }
}

/// 「我是谁」：输入 MeowID（六位编号 / temp-编号），昵称由主项目身份表解析
struct CWIdentitySheet: View {
    @Environment(\.dismiss) private var dismiss

    let onSave: (String) -> Void
    @State private var text: String
    @FocusState private var focused: Bool

    init(current: String, onSave: @escaping (String) -> Void) {
        self.onSave = onSave
        _text = State(initialValue: current)
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("MeowID"),
                        footer: Text("六位编号（如 000001）或临时身份（temp-000012）。留空 = 手机用户。昵称会自动从主项目身份表读取。")) {
                    TextField("000001", text: $text)
                        .keyboardType(.asciiCapable)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .focused($focused)
                    if !text.isEmpty, CWConfig.normalizedMeowID(text).isEmpty {
                        Text("格式不对：要 6 位数字（000001）或 temp-6 位数字（temp-000012）")
                            .font(.caption)
                            .foregroundColor(CWTheme.coral)
                    }
                }
                Section {
                    Button {
                        onSave(CWConfig.normalizedMeowID(text))
                        dismiss()
                    } label: {
                        Text("保存")
                    }
                    .disabled(!text.isEmpty && CWConfig.normalizedMeowID(text).isEmpty)
                }
            }
            .navigationTitle("我是谁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onAppear { focused = true }
        }
    }
}

