import Foundation
import AVFoundation
import VideoToolbox
import CoreMedia
import UIKit

// MARK: - WebSocket 链路（视频与麦克风各一条，和 .cam 前端一致）

final class CWLink: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    let name: String
    private var url: URL?
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var retry = 0
    private var generation = 0
    private var reconnectScheduled = false
    private var inflight = 0
    private let lock = NSLock()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    var onOpen: (() -> Void)?
    var onText: (([String: Any]) -> Void)?
    var onState: ((Bool, String) -> Void)?

    init(name: String) {
        self.name = name
        super.init()
    }

    var isOpen: Bool { task?.state == .running }

    /// 是否已经交给它一个连接（连接中/已连上/等待重连都算），避免 configure 反复重连
    var isActive: Bool { !stopped && (task != nil || reconnectScheduled) }

    func start(url: URL) {
        generation += 1
        reconnectScheduled = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        self.url = url
        stopped = false
        retry = 0
        resetInflight()
        open(generation)
    }

    func stop() {
        generation += 1
        reconnectScheduled = false
        stopped = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        resetInflight()
    }

    private func open(_ gen: Int) {
        guard !stopped, gen == generation, let url else { return }
        task?.cancel(with: .goingAway, reason: nil)
        resetInflight()
        let next = session.webSocketTask(with: url)
        task = next
        next.resume()
        listen(next, gen)
    }

    private func resetInflight() {
        lock.lock()
        inflight = 0
        lock.unlock()
    }

    private func listen(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self, weak t] result in
            guard let self, let t, self.task === t, gen == self.generation else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if let data = text.data(using: .utf8),
                       let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        self.onText?(object)
                    }
                case .data(let data):
                    _ = data
                @unknown default:
                    break
                }
                self.listen(t, gen)
            case .failure(let error):
                self.dropped(error.localizedDescription, gen)
            }
        }
    }

    private func dropped(_ reason: String, _ gen: Int) {
        guard !stopped, gen == generation, !reconnectScheduled else { return }
        reconnectScheduled = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        onState?(false, reason)
        let delays: [Double] = [1, 2, 5, 10, 30]
        let delay = delays[min(retry, delays.count - 1)]
        retry += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, gen == self.generation else { return }
            self.reconnectScheduled = false
            self.open(gen)
        }
    }

    func send(json: [String: Any]) {
        guard let task, task.state == .running,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    func send(binary: Data) {
        guard let task, task.state == .running else { return }
        lock.lock()
        if inflight >= 3 {
            lock.unlock()
            return
        }
        inflight += 1
        lock.unlock()
        task.send(.data(binary)) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.inflight = max(0, self.inflight - 1)
            self.lock.unlock()
        }
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        CWAuth.handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        onState?(true, "已连接")
        onOpen?()
        // 连接稳定 10 秒才把退避清零，避免“连上就断”的 1 秒风暴
        let gen = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, gen == self.generation, self.isOpen else { return }
            self.retry = 0
        }
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        guard webSocketTask === task else { return }
        dropped("已断开（\(closeCode.rawValue)）", generation)
    }
}

// MARK: - 相机

final class CWCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let frames = DispatchQueue(label: "cw.camera.frames")
    private let control = DispatchQueue(label: "cw.camera.control")
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var isRunning = false

    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        // 关键：相机不要自动配置 App 的音频会话，否则会和麦克风/播放互相打断
        session.automaticallyConfiguresApplicationAudioSession = false
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? UInt) ?? 0
            NSLog("[CatCam] 相机会话被打断 reason=%d", raw)
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.control.async {
                guard self.isRunning, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
        center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] note in
            NSLog("[CatCam] 相机会话错误：%@", String(describing: note.userInfo))
            guard let self else { return }
            self.control.async {
                guard self.isRunning, !self.session.isRunning else { return }
                self.session.startRunning()
            }
        }
    }

    func start(position: AVCaptureDevice.Position) throws {
        try control.sync { try startLocked(position: position) }
    }

    private func startLocked(position: AVCaptureDevice.Position) throws {
        if !configured {
            try configure(position: position)
            configured = true
        }
        if !session.isRunning {
            session.startRunning()
        }
        isRunning = session.isRunning
    }

    func stop() {
        control.sync { stopLocked() }
    }

    private func stopLocked() {
        if session.isRunning {
            session.stopRunning()
        }
        isRunning = false
    }

    func switchTo(position: AVCaptureDevice.Position) throws {
        try control.sync { try switchLocked(position: position) }
    }

    private func switchLocked(position: AVCaptureDevice.Position) throws {
        guard configured else {
            try configure(position: position)
            configured = true
            return
        }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "CatCam", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到 \(position == .front ? "前置" : "后置") 摄像头"])
        }
        let next = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if let old = input {
            session.removeInput(old)
        }
        guard session.canAddInput(next) else {
            if let old = input { session.addInput(old) }
            session.commitConfiguration()
            throw NSError(domain: "CatCam", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法切换摄像头输入"])
        }
        session.addInput(next)
        input = next
        self.position = position
        applyRotation(position: position)
        session.commitConfiguration()
        applyFrameRate(device: device)
    }

    private func configure(position: AVCaptureDevice.Position) throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw NSError(domain: "CatCam", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "没有可用摄像头"])
        }
        let next = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }
        guard session.canAddInput(next) else {
            session.commitConfiguration()
            throw NSError(domain: "CatCam", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加摄像头输入"])
        }
        session.addInput(next)
        input = next
        self.position = position

        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: frames)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw NSError(domain: "CatCam", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加视频输出"])
        }
        session.addOutput(output)
        applyRotation(position: position)
        session.commitConfiguration()
        applyFrameRate(device: device)
    }

    private func applyRotation(position: AVCaptureDevice.Position) {
        guard let connection = output.connection(with: .video) else { return }
        if #available(iOS 17.0, *) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = (position == .front)
        }
    }

    private func applyFrameRate(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let duration = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
            }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        } catch {
            NSLog("[CatCam] 设置帧率失败：%@", error.localizedDescription)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(buffer, pts)
    }
}

// MARK: - H.264 编码（Annex-B，给 .cam 的二进制帧）

final class CWVideoEncoder {
    private var session: VTCompressionSession?
    private var size: (Int, Int) = (0, 0)
    private var pending = 0
    private var forceKey = false
    private var fps = 30
    private var bitrate = 2_000_000
    private let lock = NSLock()
    private let sessionLock = NSRecursiveLock()
    private let queue = DispatchQueue(label: "cw.encoder")

    var onConfig: ((Int, Int) -> Void)?
    var onPacket: ((Data, Bool, UInt64) -> Void)?

    private static let callback: VTCompressionOutputCallback = { refcon, _, status, _, sampleBuffer in
        guard status == noErr, let sampleBuffer, let refcon else { return }
        let encoder = Unmanaged<CWVideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
        encoder.didEncode(sampleBuffer)
    }

    func configure(width: Int, height: Int) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        invalidate()
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: CWVideoEncoder.callback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            NSLog("[CatCam] VTCompressionSession 创建失败：%d", status)
            return
        }
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                             value: NSNumber(value: 2.0))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitrate))
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: fps))
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        size = (width, height)
        onConfig?(width, height)
    }

    func invalidate() {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        size = (0, 0)
        lock.lock()
        pending = 0
        lock.unlock()
    }

    func forceKeyframe() {
        lock.lock()
        forceKey = true
        lock.unlock()
    }

    func encode(_ buffer: CVPixelBuffer, pts: CMTime) {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        if session == nil || size.0 != width || size.1 != height {
            configure(width: width, height: height)
        }
        guard let session else { return }
        lock.lock()
        if pending >= 2 {
            lock.unlock()
            return
        }
        pending += 1
        let key = forceKey
        if key { forceKey = false }
        lock.unlock()

        let properties: CFDictionary? = key
            ? (([kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as NSDictionary) as CFDictionary)
            : nil
        var flags = VTEncodeInfoFlags()
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: buffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        if status != noErr {
            lock.lock()
            pending = max(0, pending - 1)
            lock.unlock()
        }
    }

    fileprivate func didEncode(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        pending = max(0, pending - 1)
        lock.unlock()

        var keyframe = true
        if let notSync = CMGetAttachment(sampleBuffer,
                                         key: kCMSampleAttachmentKey_NotSync,
                                         attachmentModeOut: nil) as? Bool {
            keyframe = !notSync
        }
        guard let annex = annexB(sampleBuffer, includeParameterSets: keyframe) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = UInt64(max(0, pts.seconds * 1_000_000))
        onPacket?(annex, keyframe, micros)
    }

    private func annexB(_ sampleBuffer: CMSampleBuffer, includeParameterSets: Bool) -> Data? {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var out = Data()
        if includeParameterSets {
            var count = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            if status == noErr {
                for index in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var length = 0
                    if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                        format,
                        parameterSetIndex: index,
                        parameterSetPointerOut: &pointer,
                        parameterSetSizeOut: &length,
                        parameterSetCountOut: nil,
                        nalUnitHeaderLengthOut: nil
                    ) == noErr, let pointer, length > 0 {
                        out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
                        out.append(pointer, count: length)
                    }
                }
            }
        }
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return out.isEmpty ? nil : out }
        var total = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(block,
                                                 atOffset: 0,
                                                 lengthAtOffsetOut: nil,
                                                 totalLengthOut: &total,
                                                 dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let base = dataPointer, total > 4 else {
            return out.isEmpty ? nil : out
        }
        let raw = UnsafeRawPointer(base).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= total {
            let b0 = UInt32(raw[offset])
            let b1 = UInt32(raw[offset + 1])
            let b2 = UInt32(raw[offset + 2])
            let b3 = UInt32(raw[offset + 3])
            let length = Int((b0 << 24) | (b1 << 16) | (b2 << 8) | b3)
            offset += 4
            guard length > 0, offset + length <= total else { break }
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(UnsafeBufferPointer(start: raw + offset, count: length))
            offset += length
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - 音频（单引擎：播放 + 录音共用一个 AVAudioEngine，避免两个引擎抢音频会话）

final class CWAudioHub {
    static let shared = CWAudioHub()

    var engine = AVAudioEngine()
    var player = AVAudioPlayerNode()
    private var lastVolume: Float = 1
    private var playerAttached = false
    private var playerConnected = false
    private var playerRate: Double = 0
    private var tapInstalled = false
    private var inputHandler: ((AVAudioPCMBuffer) -> Void)?
    private var recording = false
    private var downgradeWork: DispatchWorkItem?
    private var pending = 0
    private var lastEnd = Date.distantPast
    private let lock = NSLock()
    /// 所有 AVAudioEngine / AVAudioSession 操作都在这条串行队列上，绝不占主线程
    private let queue = DispatchQueue(label: "cw.audio.engine")

    private init() {}

    // MARK: 输出

    func play(_ data: Data, sampleRate: Double) {
        queue.async { [weak self] in
            self?.playLocked(data, sampleRate: sampleRate)
        }
    }

    private func playLocked(_ data: Data, sampleRate: Double) {
        guard data.count >= 2,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            return
        }
        do {
            try preparePlayer(format)
        } catch {
            NSLog("[CatCam] 播放引擎启动失败：%@", error.localizedDescription)
            return
        }
        let frames = data.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, let target = buffer.floatChannelData?[0] else { return }
            let samples = base.assumingMemoryBound(to: Int16.self)
            for index in 0..<frames {
                target[index] = Float(samples[index]) / 32768
            }
        }
        lock.lock()
        pending += 1
        lastEnd = Date().addingTimeInterval(0.25)
        lock.unlock()
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.pending = max(0, self.pending - 1)
            if self.pending == 0 {
                self.lastEnd = Date().addingTimeInterval(0.15)
            }
            self.lock.unlock()
        }
        if !player.isPlaying {
            player.play()
        }
    }

    private func preparePlayer(_ format: AVAudioFormat) throws {
        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        if !playerConnected || abs(playerRate - format.sampleRate) > 0.5 {
            if engine.isRunning {
                engine.stop()
            }
            if playerConnected {
                engine.disconnectNodeOutput(player)
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            playerConnected = true
            playerRate = format.sampleRate
            resetPending()
        }
        try startIfNeeded()
        if !player.isPlaying {
            player.play()
        }
    }

    // MARK: 输入

    func beginRecording(_ handler: @escaping (AVAudioPCMBuffer) -> Void,
                        completion: @escaping (Result<Double, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let rate = try self.beginRecordingLocked(handler)
                DispatchQueue.main.async { completion(.success(rate)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func beginRecordingLocked(_ handler: @escaping (AVAudioPCMBuffer) -> Void) throws -> Double {
        // 关麦后 2 秒内又开：取消“切回 playback”的延迟任务，会话保持热的
        downgradeWork?.cancel()
        downgradeWork = nil
        let session = AVAudioSession.sharedInstance()
        try activateForRecording(session)

        if engine.isRunning {
            engine.stop()
        }
        // 停止后先 reset，再重新拿 inputNode 格式；否则很容易拿到 0 声道导致 installTap 抛异常
        engine.reset()
        resetPending()

        var format = inputFormat()
        if !isUsable(format) {
            rebuildEngine()
            format = inputFormat()
        }
        var attempts = 0
        while !isUsable(format) && attempts < 25 {
            Thread.sleep(forTimeInterval: 0.08)
            format = inputFormat()
            attempts += 1
        }
        guard isUsable(format) else {
            throw NSError(domain: "CatCam", code: 10, userInfo: [NSLocalizedDescriptionKey:
                "麦克风输入格式不可用（category=\(session.category.rawValue)，输入可用=\(session.isInputAvailable)，系统采样率=\(Int(session.sampleRate))，声道=\(format.channelCount)）"])
        }

        let input = engine.inputNode
        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        inputHandler = handler
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.inputHandler?(buffer)
        }
        tapInstalled = true
        recording = true
        try startIfNeeded()
        return format.sampleRate
    }

    private func inputFormat() -> AVAudioFormat {
        engine.inputNode.inputFormat(forBus: 0)
    }

    private func isUsable(_ format: AVAudioFormat) -> Bool {
        format.channelCount > 0 && format.sampleRate > 0
    }

    /// 丢掉旧的 IO 状态（播放图 + 旧的 inputNode 格式），下次播放会重新 attach/connect
    private func rebuildEngine() {
        if engine.isRunning {
            engine.stop()
        }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        player.volume = lastVolume
        playerAttached = false
        playerConnected = false
        playerRate = 0
        resetPending()
    }

    func endRecording() {
        queue.async { [weak self] in
            self?.endRecordingLocked()
        }
    }

    /// 切录音类别可能被相机/系统短暂占用，重试几次再报错
    private func activateForRecording(_ session: AVAudioSession) throws {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                // measurement：原始麦克风数据，系统不加 AGC/降噪（voiceChat 会把小声压得很低）
                try session.setCategory(.playAndRecord,
                                        mode: .measurement,
                                        options: [.defaultToSpeaker, .allowBluetooth])
                try session.setActive(true)
                return
            } catch {
                lastError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 0.12)
                }
            }
        }
        throw NSError(domain: "CatCam", code: 11, userInfo: [NSLocalizedDescriptionKey:
            "音频会话切不到录音：\(lastError?.localizedDescription ?? "未知错误")"])
    }

    private func endRecordingLocked() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        inputHandler = nil
        recording = false
        if engine.isRunning {
            engine.stop()
        }
        resetPending()
        try? startIfNeeded()
        // 不立刻切回 playback：留 2 秒热窗口，关麦后马上重开不会和 setCategory/setActive 抢会话。
        // 2 秒内没再开，再降回 playback（省电、释放麦克风指示）。
        downgradeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.queue.async {
                guard !self.recording else { return }
                self.setRecordingCategory(false)
            }
        }
        downgradeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    var isPlaying: Bool {
        guard lastVolume > 0.001 else { return false }
        lock.lock()
        // 只看“最后一次排入播放块的时间”：pending 万一因为引擎停/路由切换没收到完成回调，
        // 也不能把麦克风闸门永久锁死（这是“麦克风开着但一帧都不发”的元凶）。
        let value = Date() < lastEnd
        lock.unlock()
        return value
    }

    var volume: Float {
        get { lastVolume }
        set {
            lastVolume = newValue
            queue.async { [weak self] in
                self?.player.volume = newValue
            }
        }
    }

    /// 回到前台 / 打断结束 / 路由变化后重新拉起（空图不启动，避免 prepare() 抛异常）
    func reactivate() {
        queue.async { [weak self] in
            self?.reactivateLocked()
        }
    }

    private func reactivateLocked() {
        if !recording {
            setRecordingCategory(false)
        }
        if !engine.isRunning {
            // 引擎停过的话，之前排队的播放块不会再有完成回调，不清会把麦克风永久闸住
            resetPending()
        }
        try? startIfNeeded()
        if playerConnected && !player.isPlaying {
            player.play()
        }
    }

    private func startIfNeeded() throws {
        guard !engine.isRunning else { return }
        guard playerConnected || tapInstalled else { return }
        engine.prepare()
        try engine.start()
    }

    private func resetPending() {
        lock.lock()
        pending = 0
        lastEnd = Date.distantPast
        lock.unlock()
    }

    private func setRecordingCategory(_ on: Bool) {
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = on ? .playAndRecord : .playback
        let mode: AVAudioSession.Mode = on ? .measurement : .default
        if session.category == category, session.mode == mode {
            try? session.setActive(true)
            return
        }
        if engine.isRunning {
            engine.stop()
            resetPending()
        }
        do {
            try session.setCategory(category,
                                    mode: mode,
                                    options: on ? [.defaultToSpeaker, .allowBluetooth] : [])
        } catch {
            NSLog("[CatCam] 切换音频类别失败：%@", error.localizedDescription)
        }
        try? session.setActive(true)
    }
}

final class CWMic {
    private var running = false
    private var starting = false
    private var wanted = false
    private var generation = 0
    private var pending = Data()
    private(set) var rate: Double = 48000

    var onPCM: ((Data, Double) -> Void)?
    var isGated: (() -> Bool)?

    /// 异步启动：引擎操作在音频串行队列上，主线程只收回调，不会卡 UI
    func start(completion: @escaping (Error?) -> Void) {
        wanted = true
        if running {
            completion(nil)
            return
        }
        if starting {
            // 已有一次启动在路上，别重复入队；它完成时会回调最初的调用方
            completion(nil)
            return
        }
        generation += 1
        let gen = generation
        starting = true
        CWAudioHub.shared.beginRecording({ [weak self] buffer in
            self?.handle(buffer)
        }, completion: { [weak self] result in
            guard let self else { return }
            guard gen == self.generation else {
                // 这一轮已经被 stop/restart 取代，丢弃结果
                completion(nil)
                return
            }
            self.starting = false
            switch result {
            case .success(let rate):
                self.rate = rate
                self.pending.removeAll()
                if self.wanted {
                    self.running = true
                    completion(nil)
                } else {
                    CWAudioHub.shared.endRecording()
                    completion(nil)
                }
            case .failure(let error):
                self.wanted = false
                completion(error)
            }
        })
    }

    func stop() {
        generation += 1
        wanted = false
        starting = false
        running = false
        CWAudioHub.shared.endRecording()
        pending.removeAll()
    }

    func restart() {
        guard running || wanted else { return }
        stop()
        start { _ in }
    }

    /// 轻量 AGC：目标 RMS 1200，最多 4 倍（+12 dB），带 40 的噪声门和起音/释放平滑。
    /// 正常/大声说话基本在 1~1.5 倍，不会削顶；安静段才逐步加到 4 倍。
    private var inputGain: Double = 1.0

    private func applyInputGain(_ samples: inout [Int16]) {
        let n = samples.count
        guard n > 0 else { return }
        var sum = 0.0
        for value in samples {
            let d = Double(value)
            sum += d * d
        }
        let rms = (sum / Double(n)).squareRoot()
        let target = 1200.0
        var desired = 1.0
        if rms >= 40 {
            desired = min(4.0, max(1.0, target / rms))
        }
        // 起音快一点，释放慢一点，避免音量忽大忽小
        if desired > inputGain {
            inputGain = inputGain * 0.6 + desired * 0.4
        } else {
            inputGain = inputGain * 0.85 + desired * 0.15
        }
        inputGain = min(4.0, max(1.0, inputGain))
        guard inputGain > 1.01 else { return }
        for index in 0..<n {
            let value = Double(samples[index]) * inputGain
            samples[index] = Int16(max(-30000, min(30000, value.rounded())))
        }
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var int16 = [Int16](repeating: 0, count: frames)
        if let channels = buffer.floatChannelData {
            let channel = channels[0]
            for index in 0..<frames {
                let value = max(-1, min(1, channel[index]))
                int16[index] = Int16(value * 32767)
            }
        } else if let channels = buffer.int16ChannelData {
            // 少数路由/格式下输入是 Int16，直接拷贝
            let channel = channels[0]
            for index in 0..<frames {
                int16[index] = channel[index]
            }
        } else {
            return
        }
        applyInputGain(&int16)
        if let gated = isGated?(), gated {
            pending.removeAll()
            return
        }
        int16.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            let raw = UnsafeRawBufferPointer(start: base, count: frames * 2)
            pending.append(contentsOf: raw)
        }
        while pending.count >= 1920 {
            let chunk = pending.prefix(1920)
            pending.removeFirst(1920)
            onPCM?(Data(chunk), rate)
        }
    }
}

// MARK: - 音频会话（后台播放 / 后台录音）

final class CWAudioSession {
    static let shared = CWAudioSession()
    private var observers: [NSObjectProtocol] = []

    /// 来电/Siri 打断结束后，让上层把引擎重新拉起来
    var onInterruptionEnded: (() -> Void)?
    /// 真正的设备路由变化（插拔耳机/蓝牙）才回调；自己的 setCategory 引发的 categoryChange 不算
    var onRouteChanged: ((UInt) -> Void)?

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                           object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            NSLog("[CatCam] 音频中断 type=%d", raw)
            if type == .ended {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.onInterruptionEnded?()
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                           object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
            NSLog("[CatCam] 音频路由变化 reason=%d", raw)
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw) ?? .unknown
            // 关键：categoryChange / routeConfigurationChange 是我们自己切类别引起的，
            // 再触发 mic.restart 会形成死循环（音量条抖动 + 麦克风永远在重装 tap）
            let meaningful: Set<AVAudioSession.RouteChangeReason> = [
                .newDeviceAvailable, .oldDeviceUnavailable, .override, .noSuitableRouteForCategory
            ]
            guard meaningful.contains(reason) else { return }
            self?.onRouteChanged?(raw)
        })
    }

    func activate() {
        CWAudioHub.shared.reactivate()
    }
}

// MARK: - 手机端 TTS 播放（轮询 /api/tts/pending，与 .cam 的 player.js 同一套 seq 语义）

final class CWTtsPlayer {
    private var lastSeq = -1
    private var firstBatch = true
    private var lastTrace = ""
    private var inFlight = false
    private var timer: Timer?
    private var stopped = false
    private let counter = DispatchQueue(label: "cw.tts.counter")

    var base: URL?
    var volume: Float {
        get { CWAudioHub.shared.volume }
        set { CWAudioHub.shared.volume = newValue }
    }
    var onText: ((String) -> Void)?
    var onMode: ((String) -> Void)?
    var onFiltered: ((Int) -> Void)?
    var onError: ((String) -> Void)?

    var isPlaying: Bool {
        CWAudioHub.shared.isPlaying
    }

    func start() {
        stopped = false
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        activate()
    }

    func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
    }

    func resync() {
        counter.sync {
            firstBatch = true
            lastTrace = ""
            inFlight = false
        }
        activate()
    }

    func reactivate() {
        activate()
    }

    private func activate() {
        // 注意：这里不能 prepare()/start()。此时播放节点还没 attach/connect，
        // AVAudioEngine 的图是空的，prepare() 会抛 NSException（真机/模拟器都会崩）。
        // 引擎在第一次 schedule() 里连好 node → mainMixer 之后再启动。
        CWAudioSession.shared.activate()
    }

    private func poll() {
        guard !stopped, let base else { return }
        var busy = false
        counter.sync { busy = inFlight; inFlight = true }
        if busy { return }
        var components = URLComponents(url: base.appendingPathComponent("api/tts/pending"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "seq", value: String(lastSeq))]
        guard let url = components?.url else {
            counter.sync { inFlight = false }
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        CWSession.shared.session.dataTask(with: request) { [weak self] data, _, error in
            guard let self else { return }
            self.counter.sync { self.inFlight = false }
            if let error {
                _ = error
                return
            }
            guard let data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            DispatchQueue.main.async {
                self.handle(object)
            }
        }.resume()
    }

    private func handle(_ object: [String: Any]) {
        let meta = object["meta"] as? [String: Any] ?? [:]
        let blocks = object["blocks"] as? [[String: Any]] ?? []
        let mode = object["mode"] as? String ?? "call"
        onMode?(mode)
        if let filtered = object["filtered"] as? Int, filtered > 0, mode == "chat" {
            onFiltered?(filtered)
        }
        if let text = meta["text"] as? String, !text.isEmpty {
            let key = "\(object["mid"] as? Int ?? 0)|\(text)"
            if key != lastTrace {
                lastTrace = key
                onText?(text)
            }
        }
        guard !blocks.isEmpty else { return }
        var sr = 32000.0
        if let value = meta["sample_rate"] as? NSNumber, value.doubleValue > 0 {
            sr = value.doubleValue
        }
        if firstBatch {
            firstBatch = false
            let newest = max(0, (object["seq"] as? Int ?? 0) - 1)
            lastSeq = max(-1, newest - 4)
        }
        for block in blocks {
            guard let seq = block["seq"] as? Int, seq > lastSeq else { continue }
            lastSeq = seq
            guard let pcm = block["pcm"] as? String, let data = Data(base64Encoded: pcm) else { continue }
            schedule(data, sampleRate: sr)
        }
    }

    private func schedule(_ data: Data, sampleRate: Double) {
        CWAudioHub.shared.play(data, sampleRate: sampleRate)
    }
}

// MARK: - 聊天 / 识别字幕 / 模式

final class CWChat {
    var base: URL?
    var username: String = "手机用户"
    var onUserLine: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private var timer: Timer?
    private var audioBusy = false
    private var pendingName: String?

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollAudio()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func resync() {
        audioBusy = false
    }

    func send(_ text: String) {
        guard let base else { return }
        var components = URLComponents(url: base.appendingPathComponent("api/chat"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "text", value: text),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "source", value: "phone")
        ]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        CWSession.shared.session.dataTask(with: request) { [weak self] _, response, error in
            if let error {
                self?.onError?(error.localizedDescription)
                return
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                self?.onError?("发送失败（HTTP \(http.statusCode)）")
            }
        }.resume()
    }

    private func pollAudio() {
        guard !audioBusy, let base else { return }
        audioBusy = true
        var request = URLRequest(url: base.appendingPathComponent("api/phone/audio"))
        request.timeoutInterval = 5
        CWSession.shared.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.audioBusy = false
                guard let data, var raw = String(data: data, encoding: .utf8) else { return }
                raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.hasPrefix("(") { raw.removeFirst() }
                if raw.hasSuffix(")") { raw.removeLast() }
                guard let dict = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let text = dict["text"] as? String, !text.isEmpty else { return }
                self.onUserLine?(text)
            }
        }.resume()
    }
}

final class CWMode {
    var base: URL?
    private(set) var mode = "call"
    var onChange: ((String) -> Void)?

    func load() {
        guard let base else { return }
        var request = URLRequest(url: base.appendingPathComponent("api/mode"))
        request.timeoutInterval = 6
        CWSession.shared.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let mode = dict["mode"] as? String else { return }
            DispatchQueue.main.async {
                self.mode = mode
                self.onChange?(mode)
            }
        }.resume()
    }

    func toggle() {
        guard let base else { return }
        let next = mode == "call" ? "chat" : "call"
        var components = URLComponents(url: base.appendingPathComponent("api/mode"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "mode", value: next)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        CWSession.shared.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var resolved = next
            if let data,
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mode = dict["mode"] as? String {
                resolved = mode
            }
            DispatchQueue.main.async {
                self.mode = resolved
                self.onChange?(resolved)
            }
        }.resume()
    }
}

// MARK: - 汇总控制器

final class CWLive: ObservableObject {
    static let shared = CWLive()

    @Published var cameraOn = false
    @Published var micOn = false
    @Published var mode = "call"
    @Published var volume: Double = 1
    @Published var muted = false
    @Published var connected = false
    @Published var aiText = ""
    @Published var userLine = ""
    @Published var hint = ""
    @Published var errorText = ""
    @Published var fps: Double = 0
    @Published var pinNote = ""
    @Published var nameLabel = "手机用户"
    @Published var uidLabel = ""

    /// 把关键事件写进 App 的日志页
    var logSink: ((String) -> Void)?

    let camera = CWCamera()
    private let encoder = CWVideoEncoder()
    private let videoLink = CWLink(name: "video")
    private let audioLink = CWLink(name: "audio")
    private let mic = CWMic()
    private let player = CWTtsPlayer()
    private let chat = CWChat()
    private let modeClient = CWMode()

    private var base: URL?
    private var wsURL: URL?
    private var appliedConfig: CWConfig?
    private var configuredKey = ""
    private var endpointWork: DispatchWorkItem?
    private var started = false
    private var cameraPreferred = false
    private var micWanted = false
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var meowID = ""
    private var username = "手机用户"
    private var videoSize: (Int, Int)?
    private var frameCount = 0
    private var fpsStamp = Date()
    private var lineHideAt: Date?
    private var hintHideAt: Date?
    private var lastRouteFix = Date.distantPast
    private var clearTimer: Timer?

    private init() {}

    // MARK: 配置与生命周期

    /// 幂等：启动、设置变更、回前台、切 Tab 都可以调用。
    /// 地址缺失时只留痕不启动；地址补上后下一次调用会自动补连（不再依赖“只配置一次”的时序）。
    func configure(_ config: CWConfig) {
        appliedConfig = config

        // 身份与地址无关，永远更新
        let meow = CWConfig.normalizedMeowID(config.meowID)
        meowID = meow
        username = meow.isEmpty ? "手机用户" : meow
        chat.username = username
        publish {
            self.nameLabel = self.username
            self.uidLabel = ""
        }

        guard let host = config.camHost else {
            endpointWork?.cancel()
            endpointWork = nil
            configuredKey = ""
            base = nil
            wsURL = nil
            stopLinks()
            publish {
                self.connected = false
                self.errorText = "设置里没填 PC 地址"
            }
            logSink?("未配置 PC 地址，推流不会启动（去「设置 → PC 连接」填）")
            return
        }

        // 地址/协议变了：0.4s 防抖再重连，避免在设置里逐字输入 IP 时把链路反复掐断
        let key = "\(host)|\(config.camHTTPS)"
        if key == configuredKey {
            endpointWork?.cancel()
            endpointWork = nil
            ensureLinks()
            refreshNickname()
            return
        }
        endpointWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyEndpoint(config)
        }
        endpointWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func applyEndpoint(_ config: CWConfig) {
        endpointWork = nil
        guard let host = config.camHost else {
            configuredKey = ""
            base = nil
            wsURL = nil
            stopLinks()
            return
        }
        let key = "\(host)|\(config.camHTTPS)"
        guard key != configuredKey else {
            ensureLinks()
            return
        }
        configuredKey = key
        let scheme = config.camHTTPS ? "https" : "http"
        let wsScheme = config.camHTTPS ? "wss" : "ws"
        let port = config.camHTTPS ? 8443 : 8445
        base = URL(string: "\(scheme)://\(host):\(port)")
        wsURL = URL(string: "\(wsScheme)://\(host):\(port)/ws")
        player.base = base
        chat.base = base
        modeClient.base = base
        if started {
            stopLinks()
            if let wsURL {
                videoLink.start(url: wsURL)
                audioLink.start(url: wsURL)
            }
            modeClient.load()
        }
        logSink?("推流目标：\(wsURL?.absoluteString ?? "（空）")")
        refreshNickname()
    }

    private func ensureLinks() {
        guard started, let wsURL else { return }
        if !videoLink.isActive {
            videoLink.start(url: wsURL)
        }
        if !audioLink.isActive {
            audioLink.start(url: wsURL)
        }
    }

    private func stopLinks() {
        videoLink.stop()
        audioLink.stop()
    }


    // MARK: 用户模式（MeowID）

    /// 切换 MeowID：空 = 手机用户。身份变了要立刻重发 user 并回查昵称。
    func applyIdentity(_ raw: String) {
        let clean = CWConfig.normalizedMeowID(raw)
        meowID = clean
        username = clean.isEmpty ? "手机用户" : clean
        chat.username = username
        publish {
            self.nameLabel = self.username
            self.uidLabel = ""
        }
        videoLink.send(json: ["t": "user", "name": username])
        audioLink.send(json: ["t": "user", "name": username])
        refreshNickname()
    }

    /// 编号 → 昵称（走 `.cam` 的 /api/who，最终查主项目身份表）
    private func refreshNickname() {
        guard let base, !username.isEmpty else { return }
        var components = URLComponents(url: base.appendingPathComponent("api/who"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "uid", value: username)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        CWSession.shared.session.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let nickname = (dict["nickname"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async {
                let uid = self.meowID
                if !nickname.isEmpty, nickname != uid {
                    self.nameLabel = nickname
                    self.uidLabel = uid.isEmpty ? "" : "编号 \(uid)"
                } else {
                    self.nameLabel = self.username
                    self.uidLabel = ""
                }
            }
        }.resume()
    }

    func setVolume(_ value: Double) {
        volume = max(0, min(1, value))
        applyVolume()
        UserDefaults.standard.set(volume, forKey: "cw_cam_volume")
    }

    func toggleMute() {
        muted.toggle()
        applyVolume()
        UserDefaults.standard.set(muted, forKey: "cw_cam_muted")
        flash(muted ? "语音已静音" : "语音音量 \(Int(volume * 100))%")
    }

    private func applyVolume() {
        player.volume = Float(muted ? 0 : volume)
    }

    func start() {
        guard !started else { return }
        started = true
        if let saved = UserDefaults.standard.object(forKey: "cw_cam_volume") as? NSNumber {
            volume = max(0, min(1, saved.doubleValue))
        }
        muted = UserDefaults.standard.bool(forKey: "cw_cam_muted")
        applyVolume()
        CWAudioSession.shared.activate()
        CWAudioSession.shared.onInterruptionEnded = { [weak self] in
            guard let self else { return }
            self.player.reactivate()
            if self.micOn, Date().timeIntervalSince(self.lastRouteFix) > 1.5 {
                self.lastRouteFix = Date()
                self.mic.restart()
            }
        }
        CWAudioSession.shared.onRouteChanged = { [weak self] _ in
            guard let self, self.micOn else { return }
            guard Date().timeIntervalSince(self.lastRouteFix) > 1.5 else { return }
            self.lastRouteFix = Date()
            self.player.reactivate()
            self.mic.restart()
        }
        CWPins.onEvent = { [weak self] note in
            self?.publish {
                self?.pinNote = note
                self?.hint = note
                self?.hintHideAt = Date().addingTimeInterval(6)
            }
        }
        wireLinks()
        wireMedia()
        if let config = appliedConfig {
            configure(config)
        } else {
            logSink?("相机页启动时还没有配置，等设置变化后自动补连")
        }
        player.start()
        chat.start()
        modeClient.load()
        startTimers()
    }

    private func wireLinks() {
        videoLink.onState = { [weak self] up, message in
            self?.publish { self?.connected = up }
            if !up { self?.logSink?("视频链路断开：\(message)") }
        }
        audioLink.onState = { [weak self] up, message in
            self?.publish { if up { self?.connected = true } }
            if !up { self?.logSink?("音频链路断开：\(message)") }
        }
        videoLink.onOpen = { [weak self] in
            guard let self else { return }
            self.videoLink.send(json: ["t": "hello", "role": "phone"])
            self.videoLink.send(json: ["t": "user", "name": self.username])
            if self.cameraOn, let size = self.videoSize {
                self.videoLink.send(json: self.vcfg(size))
            }
            self.encoder.forceKeyframe()
            self.player.resync()
            self.chat.resync()
            self.publish { self.connected = true }
            self.logSink?("视频链路已连接")
        }
        audioLink.onOpen = { [weak self] in
            guard let self else { return }
            self.audioLink.send(json: ["t": "hello", "role": "phone"])
            self.audioLink.send(json: ["t": "user", "name": self.username])
            if self.micOn {
                self.audioLink.send(json: ["t": "acfg", "rate": self.mic.rate, "ch": 1])
            }
            self.publish { self.connected = true }
            self.logSink?("音频链路已连接")
        }
        videoLink.onText = { [weak self] object in
            guard let self else { return }
            if (object["t"] as? String) == "reqkey" {
                self.encoder.forceKeyframe()
            }
        }
    }

    private func wireMedia() {
        camera.onFrame = { [weak self] buffer, pts in
            self?.encoder.encode(buffer, pts: pts)
        }
        encoder.onConfig = { [weak self] width, height in
            guard let self else { return }
            self.videoSize = (width, height)
            if self.cameraOn {
                self.videoLink.send(json: self.vcfg((width, height)))
            }
        }
        encoder.onPacket = { [weak self] data, key, micros in
            guard let self, self.cameraOn else { return }
            var frame = Data(capacity: data.count + 10)
            frame.append(0x01)
            frame.append(key ? 1 : 0)
            var timestamp = micros.bigEndian
            withUnsafeBytes(of: &timestamp) { raw in
                frame.append(contentsOf: raw)
            }
            frame.append(data)
            self.videoLink.send(binary: frame)
            self.countFrame()
        }
        mic.isGated = { [weak self] in
            guard let self else { return false }
            return self.player.isPlaying
        }
        mic.onPCM = { [weak self] pcm, rate in
            guard let self, self.micOn else { return }
            var frame = Data(capacity: pcm.count + 1)
            frame.append(0x02)
            frame.append(pcm)
            self.audioLink.send(binary: frame)
            _ = rate
        }
        player.onText = { [weak self] text in
            self?.publish { self?.aiText = text }
        }
        player.onMode = { [weak self] mode in
            self?.publish { self?.mode = mode }
        }
        player.onFiltered = { [weak self] count in
            self?.flash("聊天模式：过滤了 \(count) 段非手机语音")
        }
        player.onError = { [weak self] message in
            self?.flash(message)
        }
        chat.onUserLine = { [weak self] text in
            self?.showUserLine(text)
        }
        chat.onError = { [weak self] message in
            self?.flash(message)
        }
        modeClient.onChange = { [weak self] mode in
            guard let self else { return }
            self.publish { self.mode = mode }
            self.flash(mode == "call" ? "通话模式：手机听全部语音" : "聊天模式：只听手机自己发起的")
        }
    }

    private func vcfg(_ size: (Int, Int)) -> [String: Any] {
        ["t": "vcfg", "codec": "avc1.42E01E", "w": size.0, "h": size.1, "fps": 30]
    }

    // MARK: 相机 / 麦克风

    func toggleCamera() {
        if cameraOn {
            cameraPreferred = false
            stopVideo()
        } else {
            cameraPreferred = true
            startVideo()
        }
    }

    private func startVideo() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.fail("没有相机权限")
                return
            }
            self.cameraPosition = self.camera.position
            DispatchQueue.global(qos: .userInitiated).async {
                guard self.cameraPreferred else { return }
                do {
                    try self.camera.start(position: self.cameraPosition)
                    self.publish { self.cameraOn = true }
                    if let size = self.videoSize {
                        self.videoLink.send(json: self.vcfg(size))
                    }
                    // 相机起来后把音频引擎/会话重新拉一次，避免被相机会话的旧配置拖死
                    CWAudioHub.shared.reactivate()
                } catch {
                    self.fail("相机启动失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func stopVideo() {
        DispatchQueue.global(qos: .userInitiated).async {
            // 先停相机（control 队列保证与 start/switch 串行），再废编码器，避免边停边编码
            self.camera.stop()
            self.encoder.invalidate()
        }
        videoLink.send(json: ["t": "vstop"])
        videoSize = nil
        publish { self.cameraOn = false }
    }

    /// 离开相机页面 / 进入后台：视频停，音频继续（.cam 的后台语义）
    func suspendVideo() {
        guard cameraOn else { return }
        stopVideo()
    }

    func resumeVideo() {
        guard cameraPreferred, !cameraOn else { return }
        startVideo()
    }

    func toggleMic() {
        // 关：UI 立刻响应，音频引擎在串行队列里慢慢收拾，绝不阻塞主线程
        if micOn || micWanted {
            micWanted = false
            mic.stop()
            publish {
                self.micOn = false
                self.hint = "麦克风已关闭"
                self.hintHideAt = Date().addingTimeInterval(2)
            }
            return
        }
        micWanted = true
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.micWanted = false
                self.fail("没有麦克风权限")
                return
            }
            guard self.micWanted else { return }
            // 先把会话采样率告诉服务端，再启动引擎（start 内部把引擎操作丢到音频队列）
            let expected = AVAudioSession.sharedInstance().sampleRate
            if expected > 0 {
                self.audioLink.send(json: ["t": "acfg", "rate": expected, "ch": 1])
            }
            self.mic.start { error in
                if let error {
                    self.micWanted = false
                    self.mic.stop()
                    self.fail("麦克风启动失败：\(error.localizedDescription)")
                    return
                }
                if abs(self.mic.rate - expected) > 0.5 {
                    self.audioLink.send(json: ["t": "acfg", "rate": self.mic.rate, "ch": 1])
                }
                if self.micWanted {
                    self.publish { self.micOn = true }
                } else {
                    self.mic.stop()
                }
            }
            // 看门狗：6 秒还没起来就复位，避免“关一次以后再也打不开”
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.micWanted, !self.micOn else { return }
                self.micWanted = false
                self.mic.stop()
                self.fail("麦克风启动超时（已复位，请再点一次）")
            }
        }
    }

    func flipCamera() {
        guard cameraOn else { return }
        cameraPosition = cameraPosition == .back ? .front : .back
        let target = cameraPosition
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try self.camera.switchTo(position: target)
                self.encoder.forceKeyframe()
                self.flash(target == .front ? "前置摄像头" : "后置摄像头")
            } catch {
                self.fail("切换摄像头失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: 聊天 / 模式

    func sendChat(_ text: String) {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        showUserLine(message)
        chat.send(message)
    }

    func toggleMode() {
        modeClient.toggle()
    }

    func dismissBubble() {
        publish { self.aiText = "" }
    }

    func sendLocalHint(_ text: String) {
        flash(text)
    }

    /// 回到前台：链路可能被系统冻结过，seq/时间线要重新对齐
    func foregrounded() {
        player.resync()
        chat.resync()
        if let config = appliedConfig {
            configure(config)
        }
        refreshNickname()
        start()
        resumeVideo()
    }

    // MARK: 内部

    private func countFrame() {
        frameCount += 1
        let now = Date()
        let span = now.timeIntervalSince(fpsStamp)
        if span >= 2 {
            let value = Double(frameCount) / span
            frameCount = 0
            fpsStamp = now
            publish { self.fps = (value * 10).rounded() / 10 }
        }
    }

    private func startTimers() {
        guard clearTimer == nil else { return }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let until = self.hintHideAt, Date() > until {
                self.hintHideAt = nil
                self.publish { self.hint = "" }
            }
            if let until = self.lineHideAt, Date() > until {
                self.lineHideAt = nil
                self.publish { self.userLine = "" }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        clearTimer = t
    }

    private func showUserLine(_ text: String) {
        publish {
            self.userLine = text
            self.lineHideAt = Date().addingTimeInterval(6)
        }
    }

    private func flash(_ text: String) {
        publish {
            self.hint = text
            self.hintHideAt = Date().addingTimeInterval(6)
        }
        logSink?(text)
    }

    private func fail(_ text: String) {
        publish {
            self.errorText = text
            self.hint = text
            self.hintHideAt = Date().addingTimeInterval(8)
        }
        logSink?(text)
        NSLog("[CatCam] %@", text)
    }

    private func publish(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
}
