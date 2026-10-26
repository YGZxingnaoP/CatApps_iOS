import SwiftUI

struct CWOperationsView: View {
    @EnvironmentObject private var store: CWStore
    @State private var tapX = "600"
    @State private var tapY = "1200"

    var body: some View {
        ZStack {
            CWBackground()
            ScrollView {
                VStack(spacing: 14) {
                    shotCard
                    actionRow
                    stopCard
                    tapCard
                }
                .padding(16)
                .padding(.bottom, 56)
            }
        }
        .navigationTitle("操作")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await store.selfCheck() }
                } label: {
                    Image(systemName: "sparkles")
                        .foregroundColor(CWTheme.pink)
                }
                .disabled(store.busy)
            }
        }
    }

    private var shotCard: some View {
        CWCard {
            HStack {
                Text("屏幕").font(.caption.weight(.semibold)).foregroundColor(CWTheme.sub)
                Spacer()
                Text(store.shotInfo.isEmpty ? "—" : store.shotInfo)
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
                    .lineLimit(1)
            }
            if let image = store.shot {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 460)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(CWTheme.pink.opacity(0.08))
                    .frame(height: 190)
                    .overlay(
                        VStack(spacing: 8) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 26))
                                .foregroundColor(CWTheme.pink.opacity(0.7))
                            Text(store.busy ? "截图中…" : "还没有截图")
                                .font(.footnote)
                                .foregroundColor(CWTheme.sub)
                        }
                    )
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            CWPillButton(title: "截图", systemImage: "camera.fill") {
                Task { await store.pullScreenshot(maxEdge: store.config.screenMaxEdge) }
            }
            CWPillButton(title: "原图", systemImage: "photo", filled: false) {
                Task { await store.pullScreenshot(maxEdge: 0) }
            }
            CWPillButton(title: "读设备", systemImage: "iphone", filled: false) {
                Task { await store.refreshAll() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stopCard: some View {
        CWCard {
            Text("停止").font(.caption.weight(.semibold)).foregroundColor(CWTheme.sub)
            HStack {
                CWPillButton(title: "停止当前动作", systemImage: "stop.fill", tint: CWTheme.coral) {
                    Task { await store.stop() }
                }
                Spacer()
                Text(store.lastStop.isEmpty ? "—" : store.lastStop)
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
                    .multilineTextAlignment(.trailing)
            }
            Text("只打断当前动作序列（/actions），不会退出 App 或 Runner；PC 端串行队列会收到 E_CANCELLED。")
                .font(.caption2)
                .foregroundColor(CWTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tapCard: some View {
        CWCard {
            Text("点按").font(.caption.weight(.semibold)).foregroundColor(CWTheme.sub)
            HStack(spacing: 10) {
                coordinateField("x", text: $tapX)
                coordinateField("y", text: $tapY)
                Spacer()
                CWPillButton(title: "发送", systemImage: "paperplane.fill") {
                    guard let x = Int(tapX), let y = Int(tapY) else {
                        store.log("坐标不是整数", level: "警告")
                        return
                    }
                    Task { await store.tap(x: x, y: y) }
                }
            }
            HStack {
                CWPillButton(title: "回桌面", systemImage: "house.fill", filled: false) {
                    Task { await store.pressHome() }
                }
                Spacer()
                Text("坐标是截图像素")
                    .font(.caption2)
                    .foregroundColor(CWTheme.sub)
            }
        }
    }

    private func coordinateField(_ title: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundColor(CWTheme.sub)
            TextField(title, text: text)
                .keyboardType(.numberPad)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .frame(width: 74)
        }
    }
}
