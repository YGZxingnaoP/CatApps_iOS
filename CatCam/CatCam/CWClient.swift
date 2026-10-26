import Foundation

struct CWPing: Equatable {
    var app: String
    var version: String
    var build: String
    var session: Bool
}

struct CWDevice: Equatable {
    var model: String
    var ios: String
    var name: String
    var pixelWidth: Int
    var pixelHeight: Int
    var pointWidth: Double
    var pointHeight: Double
    var scale: Double
    var orientation: String
    var capabilities: [String]
    var warnings: [String]
}

struct CWScreenshot {
    var data: Data
    var reportedSize: String
    var reportedScale: String
    var contentType: String
}

struct CWStopResult {
    var cancelled: Bool
    var remaining: Int
}

enum CWClientError: LocalizedError {
    case badURL
    case transport(String)
    case http(Int)
    case envelope(String, String)
    case payload(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "地址无效"
        case .transport(let message):
            return "网络错误：\(message)"
        case .http(let status):
            return "HTTP \(status)"
        case .envelope(let code, let message):
            return message.isEmpty ? code : "\(code)：\(message)"
        case .payload(let message):
            return "响应解析失败：\(message)"
        }
    }
}

final class CWClient {
    private let base: URL
    private let token: String
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 20
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    init(base: URL, token: String) {
        self.base = base
        self.token = token
    }

    func ping() async throws -> CWPing {
        let data = try await call("GET", "ping")
        return CWPing(app: data["app"] as? String ?? "?",
                      version: data["version"] as? String ?? "?",
                      build: data["build"] as? String ?? "",
                      session: data["session"] as? Bool ?? false)
    }

    func device() async throws -> CWDevice {
        let data = try await call("GET", "device")
        let screen = data["screen"] as? [String: Any] ?? [:]
        let system = data["system"] as? [String: Any] ?? [:]
        let pixel = screen["pixel"] as? [Any] ?? []
        let point = screen["point"] as? [Any] ?? []
        return CWDevice(model: system["model"] as? String ?? "?",
                        ios: system["ios"] as? String ?? "?",
                        name: system["name"] as? String ?? "?",
                        pixelWidth: CWClient.intValue(pixel, at: 0),
                        pixelHeight: CWClient.intValue(pixel, at: 1),
                        pointWidth: CWClient.doubleValue(point, at: 0),
                        pointHeight: CWClient.doubleValue(point, at: 1),
                        scale: (screen["scale"] as? NSNumber)?.doubleValue ?? 0,
                        orientation: screen["orientation"] as? String ?? "?",
                        capabilities: data["capabilities"] as? [String] ?? [],
                        warnings: data["warnings"] as? [String] ?? [])
    }

    func screenshot(maxEdge: Int) async throws -> CWScreenshot {
        var query = [URLQueryItem(name: "format", value: "png")]
        if maxEdge > 0 { query.append(URLQueryItem(name: "max_edge", value: "\(maxEdge)")) }
        var request = URLRequest(url: try makeURL("screenshot", query: query))
        request.httpMethod = "GET"
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await send(request)
        guard response.statusCode == 200 else { throw CWClientError.http(response.statusCode) }
        let contentType = response.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
        guard contentType.hasPrefix("image") else {
            throw CWClientError.payload("不是图片响应（\(contentType)）")
        }
        return CWScreenshot(data: data,
                            reportedSize: response.value(forHTTPHeaderField: "X-CW-Size") ?? "",
                            reportedScale: response.value(forHTTPHeaderField: "X-CW-Scale") ?? "",
                            contentType: contentType)
    }

    func stop() async throws -> CWStopResult {
        let data = try await call("POST", "stop")
        return CWStopResult(cancelled: data["cancelled"] as? Bool ?? false,
                            remaining: (data["remaining_steps"] as? NSNumber)?.intValue ?? 0)
    }

    func actions(steps: [[String: Any]], delayMs: Int = 90) async throws -> Int {
        let data = try await call("POST", "actions", body: ["steps": steps, "delay_ms": delayMs])
        return (data["executed"] as? NSNumber)?.intValue ?? 0
    }

    func probe(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        do {
            let (_, response) = try await send(request)
            return response.statusCode < 500
        } catch {
            return false
        }
    }

    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: try makeURL(path))
        request.httpMethod = method
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await send(request)
        if response.statusCode == 401 {
            throw CWClientError.envelope("E_UNAUTHORIZED", "token 校验失败")
        }
        guard response.statusCode == 200 else {
            throw CWClientError.http(response.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CWClientError.payload("不是 JSON")
        }
        if let ok = root["ok"] as? Bool, ok == false {
            throw CWClientError.envelope(root["code"] as? String ?? "E_INTERNAL",
                                         root["message"] as? String ?? "")
        }
        return root["data"] as? [String: Any] ?? [:]
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await CWClient.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CWClientError.transport("没有 HTTP 响应")
            }
            return (data, http)
        } catch let error as CWClientError {
            throw error
        } catch {
            throw CWClientError.transport(error.localizedDescription)
        }
    }

    private func makeURL(_ relative: String, query: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: base.absoluteString + "/" + relative) else {
            throw CWClientError.badURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CWClientError.badURL }
        return url
    }

    private static func intValue(_ array: [Any], at index: Int) -> Int {
        guard index < array.count, let number = array[index] as? NSNumber else { return 0 }
        return number.intValue
    }

    private static func doubleValue(_ array: [Any], at index: Int) -> Double {
        guard index < array.count, let number = array[index] as? NSNumber else { return 0 }
        return number.doubleValue
    }
}
