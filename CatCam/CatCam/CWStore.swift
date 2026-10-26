import Foundation
import UIKit

enum CWLamp: Equatable {
    case unknown
    case checking
    case up
    case down
    case off
}

enum CWLampText {
    static func label(_ lamp: CWLamp) -> String {
        switch lamp {
        case .up:
            return "在线"
        case .down:
            return "不可达"
        case .checking:
            return "检查中"
        case .unknown:
            return "未检查"
        case .off:
            return "未配置"
        }
    }
}

struct CWLogLine: Identifiable, Equatable {
    let id: UUID
    let at: Date
    let level: String
    let text: String

    init(id: UUID = UUID(), at: Date, level: String, text: String) {
        self.id = id
        self.at = at
        self.level = level
        self.text = text
    }
}

@MainActor
final class CWStore: ObservableObject {
    static let logKey = "cw_app_log"
    static let logLimit = 200

    @Published var config: CWConfig {
        didSet { config.save() }
    }
    @Published private(set) var logs: [CWLogLine] = []
    @Published private(set) var runnerLamp: CWLamp = .unknown
    @Published private(set) var controlLamp: CWLamp = .unknown
    @Published private(set) var relayLamp: CWLamp = .unknown
    @Published private(set) var ping: CWPing?
    @Published private(set) var device: CWDevice?
    @Published private(set) var shot: UIImage?
    @Published private(set) var shotInfo: String = ""
    @Published private(set) var lastStop: String = ""
    @Published private(set) var warnings: [String] = []
    @Published private(set) var busy: Bool = false
    @Published private(set) var failStreak: Int = 0
    @Published private(set) var lastSuccess: Date?
    @Published private(set) var localIP: String?

    private var pollTask: Task<Void, Never>?
    private var serverWarnings: [String] = []
    private var screenshotWarning: String?

    init() {
        config = CWConfig.load()
        logs = CWStore.loadPersistedLogs()
        localIP = CWLocalIPv4()
    }

    func refreshLocalIP() {
        localIP = CWLocalIPv4()
    }

    func startPolling(interval: TimeInterval = 3) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func pollOnce() async {
        guard !busy else { return }
        let before = (runnerLamp, controlLamp, relayLamp)
        await refreshRunner(verbose: false)
        await refreshPC(verbose: false)
        if before != (runnerLamp, controlLamp, relayLamp) {
            log("状态更新：Runner \(CWLampText.label(runnerLamp))，服务 \(CWLampText.label(controlLamp))，中继 \(CWLampText.label(relayLamp))")
        }
    }

    func selfCheck() async {
        guard begin("自检") else { return }
        defer { busy = false }
        log("开始自检：Runner / PC / 设备 / 截图")
        await refreshRunner()
        await refreshPC()
        await loadDevice()
        await capture(maxEdge: config.screenMaxEdge)
        log("自检结束", level: "信息")
    }

    func refreshAll() async {
        guard begin("刷新") else { return }
        defer { busy = false }
        await refreshRunner()
        await refreshPC()
        await loadDevice()
    }

    func pullScreenshot(maxEdge: Int) async {
        guard begin("截图") else { return }
        defer { busy = false }
        await capture(maxEdge: maxEdge)
    }

    func stop() async {
        guard begin("停止") else { return }
        defer { busy = false }
        await sendStop()
    }

    func tap(x: Int, y: Int) async {
        guard begin("点按") else { return }
        defer { busy = false }
        await run(steps: [["action": "tap", "x": x, "y": y]], label: "点按 (\(x), \(y))")
    }

    func pressHome() async {
        guard begin("回桌面") else { return }
        defer { busy = false }
        await run(steps: [["action": "press_key", "key": "home"]], label: "press_key home")
    }

    func resetConfig() {
        CWConfig.clear()
        config = CWConfig()
        log("配置已恢复默认值")
    }

    func clearLogs() {
        logs.removeAll()
        persistLogs()
    }

    func log(_ text: String, level: String = "信息") {
        logs.append(CWLogLine(at: Date(), level: level, text: text))
        if logs.count > CWStore.logLimit {
            logs.removeFirst(logs.count - CWStore.logLimit)
        }
        persistLogs()
        NSLog("[CatCam] %@ %@", level, text)
    }

    private func begin(_ label: String) -> Bool {
        if busy {
            log("\(label)：上一项还在执行，稍后再试", level: "警告")
            return false
        }
        busy = true
        return true
    }

    private func client() -> CWClient {
        CWClient(base: config.runnerCWBaseURL, token: config.token)
    }

    private func markSuccess() {
        failStreak = 0
        lastSuccess = Date()
    }

    private func refreshRunner(verbose: Bool = true) async {
        let previous = runnerLamp
        if verbose || previous == .unknown {
            runnerLamp = .checking
        }
        do {
            let info = try await client().ping()
            ping = info
            runnerLamp = .up
            markSuccess()
            if verbose {
                log("Runner 在线：\(info.app) \(info.version) session=\(info.session)", level: "成功")
            } else if previous == .down {
                log("Runner 恢复（\(info.app) \(info.version)）", level: "成功")
            }
        } catch {
            ping = nil
            runnerLamp = .down
            failStreak += 1
            if verbose || failStreak == 1 {
                log("Runner 不可达（USB / launcher / runner 被回收）：\(error.localizedDescription)", level: "错误")
            }
        }
    }

    private func refreshPC(verbose: Bool = true) async {
        let previousControl = controlLamp
        let previousRelay = relayLamp
        guard let control = config.controlBaseURL, let relay = config.relayBaseURL else {
            controlLamp = .off
            relayLamp = .off
            if verbose {
                log("未配置 cw_pc_host，跳过 \(config.controlPort) / \(config.videoPort) 探活", level: "警告")
            }
            return
        }
        if verbose || previousControl == .unknown {
            controlLamp = .checking
        }
        if verbose || previousRelay == .unknown {
            relayLamp = .checking
        }
        let probe = client()
        async let controlUp = probe.probe(control)
        async let relayUp = probe.probe(relay)
        let controlOnline = await controlUp
        let relayOnline = await relayUp
        controlLamp = controlOnline ? .up : .down
        relayLamp = relayOnline ? .up : .down
        if verbose || controlLamp != previousControl {
            log("CatPaws 服务 \(control.absoluteString) \(CWLampText.label(controlLamp))",
                level: controlOnline ? "成功" : "错误")
        }
        if verbose || relayLamp != previousRelay {
            log("中继 \(relay.absoluteString) \(CWLampText.label(relayLamp))",
                level: relayOnline ? "成功" : "错误")
        }
    }

    private func loadDevice(verbose: Bool = true) async {
        do {
            let info = try await client().device()
            device = info
            serverWarnings = info.warnings
            recomputeWarnings()
            markSuccess()
            if verbose {
                log("设备 \(info.model) \(info.pixelWidth)x\(info.pixelHeight) point=\(Int(info.pointWidth))x\(Int(info.pointHeight)) scale=\(info.scale) iOS \(info.ios)",
                    level: "成功")
            }
        } catch {
            device = nil
            if verbose {
                log("读取 /cw/v1/device 失败：\(error.localizedDescription)", level: "错误")
            }
        }
    }

    private func capture(maxEdge: Int) async {
        do {
            let result = try await client().screenshot(maxEdge: maxEdge)
            guard let image = UIImage(data: result.data) else {
                log("截图解码失败（\(result.contentType)，\(result.data.count) 字节）", level: "错误")
                return
            }
            shot = image
            let reported = result.reportedSize.isEmpty ? "?" : result.reportedSize
            shotInfo = "\(Int(image.size.width))×\(Int(image.size.height)) · \(result.data.count / 1024) KB · max_edge=\(maxEdge)"
            markSuccess()
            log("截图成功：\(shotInfo) · server=\(reported)", level: "成功")
            checkResolution(reported: result.reportedSize, maxEdge: maxEdge)
        } catch {
            log("截图失败：\(error.localizedDescription)", level: "错误")
        }
    }

    private func checkResolution(reported: String, maxEdge: Int) {
        guard let device = device else {
            screenshotWarning = nil
            recomputeWarnings()
            return
        }
        let parts = reported.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else {
            screenshotWarning = nil
            recomputeWarnings()
            return
        }
        var expectWidth = device.pixelWidth
        var expectHeight = device.pixelHeight
        let longest = max(expectWidth, expectHeight)
        if maxEdge > 0 && longest > maxEdge {
            let ratio = Double(maxEdge) / Double(longest)
            expectWidth = Int((Double(expectWidth) * ratio).rounded())
            expectHeight = Int((Double(expectHeight) * ratio).rounded())
        }
        if abs(expectWidth - parts[0]) > 2 || abs(expectHeight - parts[1]) > 2 {
            screenshotWarning = "/device 报 \(device.pixelWidth)×\(device.pixelHeight)，截图实际 \(reported)，坐标会错位"
            log(screenshotWarning ?? "", level: "警告")
        } else {
            screenshotWarning = nil
        }
        recomputeWarnings()
    }

    private func recomputeWarnings() {
        var all = serverWarnings
        if let warning = screenshotWarning, !all.contains(warning) {
            all.append(warning)
        }
        warnings = all
    }

    private func sendStop() async {
        do {
            let result = try await client().stop()
            lastStop = result.cancelled ? "已打断，剩余 \(result.remaining) 步" : "没有执行中的动作（cancelled=false）"
            markSuccess()
            log("POST /cw/v1/stop → \(lastStop)", level: "成功")
        } catch {
            lastStop = "失败：\(error.localizedDescription)"
            log("POST /cw/v1/stop 失败：\(error.localizedDescription)", level: "错误")
        }
    }

    private func run(steps: [[String: Any]], label: String) async {
        do {
            let executed = try await client().actions(steps: steps)
            markSuccess()
            log("\(label) 完成，执行 \(executed) 步", level: "成功")
        } catch {
            log("\(label) 失败：\(error.localizedDescription)", level: "错误")
        }
    }

    private func persistLogs() {
        let rows = logs.suffix(CWStore.logLimit).map { line -> [String: Any] in
            ["t": line.at.timeIntervalSince1970, "l": line.level, "m": line.text]
        }
        UserDefaults.standard.set(rows, forKey: CWStore.logKey)
    }

    private static func loadPersistedLogs() -> [CWLogLine] {
        guard let rows = UserDefaults.standard.array(forKey: logKey) as? [[String: Any]] else {
            return []
        }
        return rows.compactMap { row in
            guard let time = row["t"] as? Double,
                  let level = row["l"] as? String,
                  let text = row["m"] as? String else { return nil }
            return CWLogLine(at: Date(timeIntervalSince1970: time), level: level, text: text)
        }
    }
}
