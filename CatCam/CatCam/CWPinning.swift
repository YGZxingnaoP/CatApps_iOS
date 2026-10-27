import Foundation
import CryptoKit
import Security

/// `.cam` 的自签证书指纹固定（TOFU：首次连接自动学习，之后必须一致）
enum CWPins {
    static let pinKey = "cw_cam_pin"
    static let lastKey = "cw_cam_fp_last"

    /// 证书校验结果回调（TOFU 学习 / 不匹配），给 UI 提示用
    static var onEvent: ((String) -> Void)?

    static var pin: String {
        get { normalize(UserDefaults.standard.string(forKey: pinKey) ?? "") }
        set { UserDefaults.standard.set(normalize(newValue), forKey: pinKey) }
    }

    static var lastSeen: String {
        get { normalize(UserDefaults.standard.string(forKey: lastKey) ?? "") }
        set { UserDefaults.standard.set(normalize(newValue), forKey: lastKey) }
    }

    /// 只保留 0-9a-f，用户可以从 `cert.pem` 里粘带冒号/大写的指纹
    static func normalize(_ raw: String) -> String {
        String(raw.lowercased().filter { "0123456789abcdef".contains($0) })
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        let chain: [SecCertificate]
        if let copied = SecTrustCopyCertificateChain(trust) as? [SecCertificate] {
            chain = copied
        } else {
            return nil
        }
        guard let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// 返回 (是否放行, 说明)。pin 为空时学习并固定；不为空时必须逐字一致。
    static func evaluate(_ challenge: URLAuthenticationChallenge) -> (Bool, String) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            return (true, "非服务器信任挑战，按系统默认处理")
        }
        guard let fp = fingerprint(of: trust) else {
            return (false, "取不到服务器证书")
        }
        lastSeen = fp
        let expected = pin
        if expected.isEmpty {
            pin = fp
            let note = "首次连接，已固定证书指纹 \(fp.prefix(16))…"
            onEvent?(note)
            return (true, note)
        }
        if expected == fp {
            return (true, "证书指纹匹配")
        }
        let note = "证书指纹不匹配：期望 \(expected.prefix(16))… 实际 \(fp.prefix(16))…"
        onEvent?(note)
        return (false, note)
    }
}

enum CWAuth {
    static func handle(_ challenge: URLAuthenticationChallenge,
                       _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (allowed, note) = CWPins.evaluate(challenge)
        if allowed {
            if let trust = challenge.protectionSpace.serverTrust {
                completion(.useCredential, URLCredential(trust: trust))
            } else {
                completion(.performDefaultHandling, nil)
            }
        } else {
            NSLog("[CatCam] 证书校验失败：%@", note)
            completion(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// 共享的 HTTP 会话（走同一套指纹校验）
final class CWSession: NSObject, URLSessionDelegate {
    static let shared = CWSession()

    private(set) lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        CWAuth.handle(challenge, completionHandler)
    }
}
