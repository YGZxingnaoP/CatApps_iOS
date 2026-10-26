import SwiftUI

struct CWSettingsView: View {
    @EnvironmentObject private var store: CWStore

    @FocusState private var focused: Field?
    @State private var controlText: String = ""
    @State private var videoText: String = ""
    @State private var runnerText: String = ""

    private enum Field: Hashable {
        case host
        case control
        case video
        case runner
        case token
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

            Section(header: Text("屏幕流"), footer: Text("推流尚未接入，这里只保存参数。")) {
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

            Section(footer: Text("配置即时保存到 UserDefaults：cw_pc_host / cw_control_port / cw_video_port / cw_runner_port / cw_token / cw_screen_fps / cw_screen_max_edge / cw_screen_bitrate / cw_allow_ocr / cw_start_in_cam")) {
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