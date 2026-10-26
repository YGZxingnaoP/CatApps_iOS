import SwiftUI

@main
struct CWCatCamApp: App {
    @StateObject private var store = CWStore()

    var body: some Scene {
        WindowGroup {
            CWRootView()
                .environmentObject(store)
                .tint(CWTheme.pink)
                .preferredColorScheme(.light)
        }
    }
}

struct CWRootView: View {
    @EnvironmentObject private var store: CWStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0
    @State private var booted = false

    var body: some View {
        TabView(selection: $selection) {
            NavigationView { CWStatusView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("状态", systemImage: "heart.fill") }
                .tag(0)
            NavigationView { CWOperationsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("操作", systemImage: "hand.tap") }
                .tag(1)
            NavigationView { CWCamView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("相机", systemImage: "camera.fill") }
                .tag(2)
            NavigationView { CWSettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(3)
        }
        .overlay(alignment: .bottomTrailing) { stopButton }
        .onAppear {
            if booted { return }
            booted = true
            Task { await store.selfCheck() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                store.refreshLocalIP()
            }
        }
    }

    private var stopButton: some View {
        Button {
            Task { await store.stop() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "stop.fill")
                Text("停止")
            }
            .font(.footnote.weight(.bold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(CWTheme.coral)
            .clipShape(Capsule())
            .shadow(color: CWTheme.coral.opacity(0.35), radius: 6, y: 2)
        }
        .padding(.trailing, 16)
        .padding(.bottom, 62)
    }
}
