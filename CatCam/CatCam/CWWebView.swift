import SwiftUI
import WebKit

struct CWCamView: View {
    @EnvironmentObject private var store: CWStore
    @State private var target: URL?

    var body: some View {
        ZStack {
            CWBackground()
            Group {
                if let target {
                    CWWebView(url: target)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 38))
                            .foregroundColor(CWTheme.pink.opacity(0.8))
                        Text("还没有载入 .cam 页面").font(.headline).foregroundColor(CWTheme.ink)
                        Text("设置里填好 cw_pc_host 后点“载入”，会用 WKWebView 打开 https://<pc>:8443/。\n自签证书暂不信任，加载失败属于预期。")
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundColor(CWTheme.sub)
                            .padding(.horizontal, 24)
                        CWPillButton(title: "载入 .cam", systemImage: "arrow.up.right.square") {
                            target = store.config.camBaseURL
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("相机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("载入") { target = store.config.camBaseURL }
            }
        }
        .onAppear {
            if target == nil, store.config.startInCam {
                target = store.config.camBaseURL
            }
        }
    }
}

struct CWWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        if uiView.url == nil {
            uiView.load(URLRequest(url: url))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            NSLog("[CatCam] .cam 载入失败：%@", error.localizedDescription)
        }
    }
}
