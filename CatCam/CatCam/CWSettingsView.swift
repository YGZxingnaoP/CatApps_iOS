import SwiftUI

struct CWSettingsView: View {
    @EnvironmentObject private var store: CWStore

    @FocusState private var focused: Field?
    @State private var controlText: String = ""
    @State private var videoText: String = ""
    @State private var runnerText: String = ""
    @State private var pinText: String = CWPins.pin
    @State private var meowText: String = ""

    private enum Field: Hashable {
        case host
        case control
        case video
        case runner
        case token
        case meowID
        case pin
    }

    var body: some View {
        Form {
            Section(header: Text("PC 连接"),
                    footer: Text("cw_pc_host 填 PC 的局域网 IP（不用带 http:// 或端口）。Runner 永远走手机本机回环。")) {
                TextField("192.168.1.10", text: $store.config.pcHost)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .focused($focused, equals: .host)
                portRow(title: "控制端口", hint: "18110", text: $controlText, field: .control) { value in
                    store.config.controlPort = value
                }
                portRow(title: "中继端口", hint: "18111", text: $videoText, field: .video) { value in
                    store.config.videoPort = value
                }
                portRow(title: "Runner 端口", hint: "8100", text: $runnerText, field: .runner) { value in
                    store.config.runnerPort = value
                }
                SecureField("Bearer token（可空）", text: $store.config.token)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .focused($focused, equals: .token)
            }

            Section(header: Text("身份（用户模式）"),
                    footer: Text("MeowID 是主项目身份表里的编号：六位数字（000001）或临时身份（temp-000012），留空 = 手机用户。昵称不由 App 填，连接后自动从 `/api/who` 读取。")) {
                HStack {
                    Text("MeowID")
                    Spacer()
                    TextField("000001", text: $meowText)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.asciiCapable)
                        .focused($focused, equals: .meowID)
                        .onChange(of: meowText) { value in
                            commitMeowID(value)
                        }
                }
                if !meowText.isEmpty, CWConfig.normalizedMeowID(meowText).isEmpty {
                    Text("格式不对：要 6 位数字，或 temp-6 位数字")
                        .font(.caption)
                        .foregroundColor(CWTheme.coral)
                }
                HStack {
                    Text("当前身份")
                    Spacer()
                    Text(store.config.identity)
                        .foregroundColor(CWTheme.sub)
                }
                HStack {
                    Text("识别到的昵称")
                    Spacer()
                    Text(CWLive.shared.nameLabel)
                        .foregroundColor(CWTheme.sub)
                }
            }

            Section(header: Text("相机（.cam）"),
                    footer: Text("证书指纹固定：留空 = 首次连接自动学习并固定；填了就必须逐字一致（可从 .vendor/.cam/cert/cert.pem 的 SHA-256 得到）。")) {
                Toggle("用 HTTPS / WSS（8443）", isOn: $store.config.camHTTPS)
                HStack {
                    Text("已固定指纹")
                    Spacer()
                    Text(CWPins.pin.isEmpty ? "（未固定）" : short(CWPins.pin))
                        .font(.caption.monospaced())
                        .foregroundColor(CWTheme.sub)
                }
                HStack {
                    Text("最近一次看到")
                    Spacer()
                    Text(CWPins.lastSeen.isEmpty ? "—" : short(CWPins.lastSeen))
                        .font(.caption.monospaced())
                        .foregroundColor(CWTheme.sub)
                }
                TextField("64 位十六进制指纹", text: $pinText)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.caption.monospaced())
                    .focused($focused, equals: .pin)
                    .onChange(of: pinText) { value in
                        let normalized = CWPins.normalize(value)
                        if normalized.isEmpty || normalized.count == 64 {
                            CWPins.pin = normalized
                        }
                    }
                Button {
                    pinText = ""
                    CWPins.pin = ""
                } label: {
                    Label("清空指纹（下次连接重新学习）", systemImage: "lock.open")
                }
            }

            Section(header: Text("屏幕流"), footer: Text("相机推流按 .cam 的 1280×720 / 30fps / 2Mbps 固定，这里的参数只用于截图。")) {
                Stepper(value: $store.config.screenFPS, in: 5...20) {
                    HStack {
                        Text("fps")
                        Spacer()
                        Text("\(store.config.screenFPS)").foregroundColor(CWTheme.sub)
                    }
                }
                Stepper(value: $store.config.screenMaxEdge, in: 720...2796, step: 80) {
                    HStack {
                        Text("max_edge")
                        Spacer()
                        Text("\(store.config.screenMaxEdge)").foregroundColor(CWTheme.sub)
                    }
                }
                Stepper(value: $store.config.screenBitrate, in: 500_000...4_000_000, step: 100_000) {
                    HStack {
                        Text("bitrate")
                        Spacer()
                        Text("\(store.config.screenBitrate)").foregroundColor(CWTheme.sub)
                    }
                }
            }

            Section(header: Text("开关")) {
                Toggle("允许 PC 调用 OCR", isOn: $store.config.allowOCR)
                Toggle("启动直接进 .cam 界面", isOn: $store.config.startInCam)
            }

            Section {
                Button {
                    store.resetConfig()
                } label: {
                    Label("恢复默认值", systemImage: "arrow.counterclockwise")
                }
                Button {
                    focused = nil
                    Task { await store.refreshAll() }
                } label: {
                    Label("保存并测试连接", systemImage: "checkmark.circle")
                }
                .disabled(store.busy)
            }

            Section(footer: Text("配置即时保存到 UserDefaults：cw_pc_host / cw_control_port / cw_video_port / cw_runner_port / cw_token / cw_meowid / cw_cam_https / cw_cam_pin（指纹）/ cw_cam_volume / cw_cam_muted")) {
                EmptyView()
            }
        }
        .cwDismissKeyboardOnScroll()
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focused = nil }
            }
        }
        .onAppear(perform: syncFromConfig)
        .onChange(of: store.config.controlPort) { _ in syncFromConfig() }
        .onChange(of: store.config.videoPort) { _ in syncFromConfig() }
        .onChange(of: store.config.runnerPort) { _ in syncFromConfig() }
        .onChange(of: focused) { newValue in
            if newValue == nil { syncFromConfig() }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func portRow(title: String,
                         hint: String,
                         text: Binding<String>,
                         field: Field,
                         commit: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(hint, text: Binding(
                get: { text.wrappedValue },
                set: { raw in
                    let digits = String(raw.filter(\.isNumber).prefix(5))
                    text.wrappedValue = digits
                    if let value = Int(digits), (1...65535).contains(value) {
                        commit(value)
                    }
                }
            ))
            .keyboardType(.numberPad)
            .multilineTextAlignment(.trailing)
            .frame(width: 96)
            .focused($focused, equals: field)
        }
    }

    private func syncFromConfig() {
        if Int(controlText) != store.config.controlPort {
            controlText = String(store.config.controlPort)
        }
        if Int(videoText) != store.config.videoPort {
            videoText = String(store.config.videoPort)
        }
        if Int(runnerText) != store.config.runnerPort {
            runnerText = String(store.config.runnerPort)
        }
        if pinText != CWPins.pin {
            pinText = CWPins.pin
        }
        if meowText != store.config.meowID {
            meowText = store.config.meowID
        }
    }

    /// MeowID 只在「空」或「格式合法」时落盘，避免边打边存半截编号
    private func commitMeowID(_ raw: String) {
        let normalized = CWConfig.normalizedMeowID(raw)
        if raw.isEmpty {
            store.config.meowID = ""
            CWLive.shared.applyIdentity("")
        } else if !normalized.isEmpty {
            store.config.meowID = normalized
            CWLive.shared.applyIdentity(normalized)
        }
    }

    private func short(_ value: String) -> String {
        guard value.count > 20 else { return value }
        return "\(value.prefix(8))…\(value.suffix(8))"
    }
}

private extension View {
    @ViewBuilder
    func cwDismissKeyboardOnScroll() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
    }
}