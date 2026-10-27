import Foundation

struct CWConfig: Equatable {
    var pcHost: String = ""
    var controlPort: Int = 18110
    var videoPort: Int = 18111
    var runnerPort: Int = 8100
    var token: String = ""
    var screenFPS: Int = 10
    var screenMaxEdge: Int = 1280
    var screenBitrate: Int = 1500000
    var allowOCR: Bool = true
    var startInCam: Bool = true
    /// MeowID：六位编号（000001）或临时身份（temp-000012）；空 = 未设置
    var meowID: String = ""
    var camHTTPS: Bool = true
}

enum CWConfigKey {
    static let host = "cw_pc_host"
    static let controlPort = "cw_control_port"
    static let videoPort = "cw_video_port"
    static let runnerPort = "cw_runner_port"
    static let token = "cw_token"
    static let screenFPS = "cw_screen_fps"
    static let screenMaxEdge = "cw_screen_max_edge"
    static let screenBitrate = "cw_screen_bitrate"
    static let allowOCR = "cw_allow_ocr"
    static let startInCam = "cw_start_in_cam"
    static let meowID = "cw_meowid"
    static let legacyNickname = "cw_nickname"
    static let camHTTPS = "cw_cam_https"

    static let all = [host, controlPort, videoPort, runnerPort, token, screenFPS, screenMaxEdge,
                      screenBitrate, allowOCR, startInCam, meowID, camHTTPS]
}

extension CWConfig {
    /// MeowID 规则与主项目 `IdSignupBridge.is_internal_uid` 一致：六位数字 / temp-六位数字
    static func isValidMeowID(_ value: String) -> Bool {
        value.range(of: "^(\\d{6}|temp-\\d{6})$", options: .regularExpression) != nil
    }

    static func normalizedMeowID(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return isValidMeowID(text) ? text : ""
    }

    /// 发给主项目的身份：有 MeowID 用 MeowID，否则沿用 .cam 网页的默认「手机用户」
    var identity: String { meowID.isEmpty ? "手机用户" : meowID }
}

extension CWConfig {
    static func load(defaults: UserDefaults = .standard) -> CWConfig {
        var config = CWConfig()
        if let value = defaults.string(forKey: CWConfigKey.host) { config.pcHost = value }
        if let value = defaults.object(forKey: CWConfigKey.controlPort) as? Int { config.controlPort = value }
        if let value = defaults.object(forKey: CWConfigKey.videoPort) as? Int { config.videoPort = value }
        if let value = defaults.object(forKey: CWConfigKey.runnerPort) as? Int { config.runnerPort = value }
        if let value = defaults.string(forKey: CWConfigKey.token) { config.token = value }
        if let value = defaults.object(forKey: CWConfigKey.screenFPS) as? Int { config.screenFPS = value }
        if let value = defaults.object(forKey: CWConfigKey.screenMaxEdge) as? Int { config.screenMaxEdge = value }
        if let value = defaults.object(forKey: CWConfigKey.screenBitrate) as? Int { config.screenBitrate = value }
        if let value = defaults.object(forKey: CWConfigKey.allowOCR) as? Bool { config.allowOCR = value }
        if let value = defaults.object(forKey: CWConfigKey.startInCam) as? Bool { config.startInCam = value }
        if let value = defaults.string(forKey: CWConfigKey.meowID) { config.meowID = value }
        if config.meowID.isEmpty,
           let legacy = defaults.string(forKey: CWConfigKey.legacyNickname) {
            // 1.1.0 把「昵称」存在 cw_nickname：如果它本身是合法 MeowID，直接迁移过来
            config.meowID = CWConfig.normalizedMeowID(legacy)
        }
        if let value = defaults.object(forKey: CWConfigKey.camHTTPS) as? Bool { config.camHTTPS = value }
        return config
    }

    func save(defaults: UserDefaults = .standard) {
        defaults.set(pcHost, forKey: CWConfigKey.host)
        defaults.set(controlPort, forKey: CWConfigKey.controlPort)
        defaults.set(videoPort, forKey: CWConfigKey.videoPort)
        defaults.set(runnerPort, forKey: CWConfigKey.runnerPort)
        defaults.set(token, forKey: CWConfigKey.token)
        defaults.set(screenFPS, forKey: CWConfigKey.screenFPS)
        defaults.set(screenMaxEdge, forKey: CWConfigKey.screenMaxEdge)
        defaults.set(screenBitrate, forKey: CWConfigKey.screenBitrate)
        defaults.set(allowOCR, forKey: CWConfigKey.allowOCR)
        defaults.set(startInCam, forKey: CWConfigKey.startInCam)
        defaults.set(meowID, forKey: CWConfigKey.meowID)
        defaults.set(camHTTPS, forKey: CWConfigKey.camHTTPS)
    }

    static func clear(defaults: UserDefaults = .standard) {
        for key in CWConfigKey.all {
            defaults.removeObject(forKey: key)
        }
    }

    var normalizedHost: String {
        var host = pcHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        if let index = host.firstIndex(of: "/") {
            host = String(host[..<index])
        }
        if let index = host.firstIndex(of: ":") {
            host = String(host[..<index])
        }
        return host
    }

    var controlBaseURL: URL? { CWConfig.baseURL(host: normalizedHost, port: controlPort, scheme: "http") }
    var relayBaseURL: URL? { CWConfig.baseURL(host: normalizedHost, port: videoPort, scheme: "http") }
    var camHost: String? {
        let host = normalizedHost
        return host.isEmpty ? nil : host
    }
    var camPort: Int { camHTTPS ? 8443 : 8445 }
    var camBaseURL: URL? {
        CWConfig.baseURL(host: normalizedHost, port: camPort, scheme: camHTTPS ? "https" : "http")
    }
    var camWSURL: URL? {
        CWConfig.baseURL(host: normalizedHost, port: camPort, scheme: camHTTPS ? "wss" : "ws")?
            .appendingPathComponent("ws")
    }
    var runnerCWBaseURL: URL {
        let port = runnerPort > 0 ? runnerPort : 8100
        return URL(string: "http://127.0.0.1:\(port)/cw/v1")!
    }

    static func baseURL(host: String, port: Int, scheme: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = trimmed
        if port > 0 { components.port = port }
        return components.url
    }
}

func CWLocalIPv4() -> String? {
    var address: String?
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return nil }
    defer { freeifaddrs(head) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = first
    while let current = pointer {
        let interface = current.pointee
        if interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
            let name = String(cString: interface.ifa_name)
            if name == "en0" || name == "en1" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = getnameinfo(interface.ifa_addr,
                                         socklen_t(interface.ifa_addr.pointee.sa_len),
                                         &host,
                                         socklen_t(host.count),
                                         nil,
                                         0,
                                         NI_NUMERICHOST)
                if result == 0 {
                    let value = String(cString: host)
                    if !value.isEmpty { address = value }
                }
            }
        }
        pointer = interface.ifa_next
    }
    return address
}
