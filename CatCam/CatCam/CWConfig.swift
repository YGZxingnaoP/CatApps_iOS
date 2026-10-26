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

    static let all = [host, controlPort, videoPort, runnerPort, token, screenFPS, screenMaxEdge, screenBitrate, allowOCR, startInCam]
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
    var camBaseURL: URL? { CWConfig.baseURL(host: normalizedHost, port: 8443, scheme: "https") }
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
