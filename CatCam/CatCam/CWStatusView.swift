import SwiftUI

struct CWStatusView: View {
    @EnvironmentObject private var store: CWStore
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            CWBackground()
            ScrollView {
                VStack(spacing: 14) {
                    header
                    connectionCard
                    deviceCard
                    if !store.warnings.isEmpty {
                        warningCard
                    }
                    footer
                }
                .padding(16)
                .padding(.bottom, 56)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(CWTheme.pink)
                }
                .disabled(store.busy)
            }
        }
        .onAppear {
            store.refreshLocalIP()
            store.startPolling()
        }
        .onDisappear {
            store.stopPolling()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                store.startPolling()
            } else {
                store.stopPolling()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CatCam")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(CWTheme.ink)
                Text("手机端 · 本机回环 8100")
                    .font(.caption)
                    .foregroundColor(CWTheme.sub)
            }
            Spacer()
            Image(systemName: "pawprint.fill")
                .font(.system(size: 26))
                .foregroundColor(CWTheme.pink)
                .padding(10)
                .background(CWTheme.pink.opacity(0.14))
                .clipShape(Circle())
        }
    }

    private var connectionCard: some View {
        CWCard {
            Text("连接").font(.caption.weight(.semibold)).foregroundColor(CWTheme.sub)
            lampRow(title: "Runner", address: "127.0.0.1:\(store.config.runnerPort)", lamp: store.runnerLamp, detail: runnerDetail)
            lampRow(title: "CatPaws 服务",
                    address: "\(hostText):\(store.config.controlPort)",
                    lamp: store.controlLamp,
                    detail: CWLampText.label(store.controlLamp))
            lampRow(title: "中继",
                    address: "\(hostText):\(store.config.videoPort)",
                    lamp: store.relayLamp,
                    detail: CWLampText.label(store.relayLamp))
            if store.runnerLamp == .down {
                Text("Runner 不可达（USB / launcher / runner 被回收）。插回 USB 约 6 秒自动恢复，状态页会自己刷回来。")
                    .font(.caption)
                    .foregroundColor(CWTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceCard: some View {
        CWCard {
            Text("设备").font(.caption.weight(.semibold)).foregroundColor(CWTheme.sub)
            if let device = store.device {
                HStack(spacing: 10) {
                    metric("机型", device.model)
                    metric("系统", device.ios)
                }
                HStack(spacing: 10) {
                    metric("分辨率", "\(device.pixelWidth)×\(device.pixelHeight)")
                    metric("缩放", String(format: "%.1f", device.scale))
                }
                if let ip = store.localIP {
                    Text("本机 IP \(ip)（插线期间 PC 可直连 :8100，拔线一起失效）")
                        .font(.caption2)
                        .foregroundColor(CWTheme.sub)
                }
                Text(device.capabilities.joined(separator: " "))
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
                    .lineLimit(2)
            } else {
                Text(store.busy ? "读取中…" : "还没有设备信息")
                    .font(.footnote)
                    .foregroundColor(CWTheme.sub)
            }
        }
    }

    private var warningCard: some View {
        CWCard {
            Text("提醒").font(.caption.weight(.semibold)).foregroundColor(CWTheme.amber)
            ForEach(store.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundColor(CWTheme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let last = store.lastSuccess {
                Text("上次成功 \(CWStatusView.timeFormatter.string(from: last)) · 连续失败 \(store.failStreak) 次")
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
            }
            NavigationLink(destination: CWLogView()) {
                HStack(spacing: 4) {
                    Image(systemName: "text.alignleft")
                    Text("查看日志")
                }
                .font(.footnote.weight(.semibold))
                .foregroundColor(CWTheme.pink)
            }
            Text("v\(appVersion)")
                .font(.caption2)
                .foregroundColor(CWTheme.sub.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var hostText: String {
        store.config.normalizedHost.isEmpty ? "未配置" : store.config.normalizedHost
    }

    private var runnerDetail: String {
        if let ping = store.ping {
            return "\(ping.app) \(ping.version) · session \(ping.session ? "已建立" : "未建立")"
        }
        return CWLampText.label(store.runnerLamp)
    }

    private func lampRow(title: String, address: String, lamp: CWLamp, detail: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            CWDot(lamp: lamp)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(CWTheme.ink)
                Text(address)
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
            }
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundColor(CWTheme.sub)
                .multilineTextAlignment(.trailing)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(CWTheme.ink)
            Text(title)
                .font(.caption2)
                .foregroundColor(CWTheme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
