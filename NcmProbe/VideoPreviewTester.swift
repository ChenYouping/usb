import Foundation
import Network
import VideoToolbox
import CoreMedia
import CoreVideo

/// 5-second windowed counters, mirrored field-for-field with DiPlay's NPVS-STAT
/// so the two sides can be compared in one glance. Emitted even when idle, so a
/// silent upstream (in=0f) is distinguishable from a frozen UI.
private final class ProbeStats {
    // Called from readQueue, main and the STAT timer queue — guard all state.
    private let lock = NSLock()
    private var start = Date()
    private var inBytes = 0
    private var parsedCfg = 0, parsedFrame = 0
    private var resync = 0, badLen = 0
    private var cfgApplied = 0, cfgFail = 0
    private var transEmpty = 0, transFrames = 0
    private var submitted = 0, submitFail = 0
    private var decOK = 0, decFail = 0
    private var shown = 0
    private var reconnect = 0
    private var idrSeen = 0, dropNoIdr = 0
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    func chunk(_ bytes: Int) { withLock { inBytes += bytes } }
    func parsed(kind: UInt8) { withLock { if kind == 1 { parsedCfg += 1 } else { parsedFrame += 1 } } }
    func didResync() { withLock { resync += 1 } }
    func badLength() { withLock { badLen += 1 } }
    func config(applied: Bool) { withLock { if applied { cfgApplied += 1 } else { cfgFail += 1 } } }
    func transcoded(empty: Bool) { withLock { if empty { transEmpty += 1 } else { transFrames += 1 } } }
    func didSubmit(ok: Bool) { withLock { if ok { submitted += 1 } else { submitFail += 1 } } }
    func decoded(ok: Bool) { withLock { if ok { decOK += 1 } else { decFail += 1 } } }
    func didShow() { withLock { shown += 1 } }
    func didReconnect() { withLock { reconnect += 1 } }
    func idr() { withLock { idrSeen += 1 } }
    func dropped(noIdr: Bool) { withLock { if noIdr { dropNoIdr += 1 } } }

    /// Returns the STAT line when the 5 s window elapsed, otherwise nil.
    func flush() -> String? {
        withLock {
            let now = Date()
            let span = now.timeIntervalSince(start)
            guard span >= 5.0 else { return nil }
            let line = String(format:
                "PROBE-STAT win=%.1fs in=%dkB parse=%d/%d resync=%d badLen=%d " +
                "cfg=%d/%d trans=%d/empty%d submit=%d/fail%d dec=%d/fail%d shown=%d recon=%d " +
                "idr=%d dropNoIdr=%d",
                span, inBytes / 1024, parsedCfg, parsedFrame, resync, badLen,
                cfgApplied, cfgFail, transFrames, transEmpty, submitted, submitFail,
                decOK, decFail, shown, reconnect, idrSeen, dropNoIdr)
            start = now
            inBytes = 0; parsedCfg = 0; parsedFrame = 0
            resync = 0; badLen = 0; cfgApplied = 0; cfgFail = 0
            transEmpty = 0; transFrames = 0; submitted = 0; submitFail = 0
            decOK = 0; decFail = 0; shown = 0; reconnect = 0
            idrSeen = 0; dropNoIdr = 0
            return line
        }
    }
}

/// Receives the NPVS stream from DiPlay's VideoFrameRelay (port 7101) and decodes
/// the Annex-B H.264/H.265 frames with VideoToolbox into CVPixelBuffers.
final class VideoPreviewTester: ObservableObject {
    @Published private(set) var status = "未连接"
    @Published private(set) var detail = ""
    @Published private(set) var decodedFrames = 0
    @Published private(set) var lastError = ""
    @Published private(set) var latestImage: CVPixelBuffer?
    @Published private(set) var step = "idle"
    /// Decode diagnostics go to a shareable log file (see DiagLog), not the UI.

    /// The VT callback gets an opaque refCon; using a weak static avoids the
    /// dangling-pointer risk of Unmanaged.passUnretained after invalidation.
    private weak static var active: VideoPreviewTester?

    private var connection: NWConnection?
    private var session: VTDecompressionSession?
    private var formatDesc: CMFormatDescription?
    private var nalLengthSize: Int = 4

    /// IMPORTANT: use a plain [UInt8] array, NOT Data. Data's integer subscript
    /// is relative to startIndex, which can drift after repeated removeFirst()
    /// and causes an out-of-bounds Swift trap inside parseFrames(). An array's
    /// indices always start at 0 and stay contiguous after removeFirst.
    private var readBuffer: [UInt8] = []
    private let readQueue = DispatchQueue(label: "npvs.read", qos: .userInitiated)

    private var wanted = false
    private var generation = 0
    private var frameIndex: Int64 = 0
    private var submitted = 0          // frames actually handed to the decoder
    private var lastDecodeStatus: OSStatus = 0
    private var callbackCount = 0

    /// IDR-driven decode state. All access is on readQueue except resets done
    /// inside teardownConnection (also dispatched on readQueue) — see below.
    /// true  = waiting for an IDR; non-IDR frames are dropped, last image is kept.
    /// false = decoding a GOP that started at an IDR.
    private var awaitingKeyframe = true
    private var lastKeyframeType = ""
    private var codecByte: UInt8 = 0  // 0 = H264, 1 = H265; set from config frame
    // While the app is backgrounded the main queue is frozen but the decode
    // thread keeps producing frames, so many "latestImage =" closures pile up.
    // Coalesce them: callbacks only overwrite a pending slot, and a single
    // scheduled refresh publishes just the newest frame. This prevents a burst
    // of stale frames flashing by when returning to the foreground.
    private var pendingImage: CVPixelBuffer?
    private var displayRefreshScheduled = false
    // Stall watchdog: the 7101 push can silently stop (CarPlay session recycled,
    // screen off) without sending FIN, leaving NWConnection stuck in receive()
    // and the UI showing "connected" with a frozen frame count. Every received
    // chunk rearms a timer; if no data arrives for STALL_TIMEOUT sec we reconnect,
    // which makes the server replay a fresh GOP and resume the stream.
    private var stallWorkItem: DispatchWorkItem?
    private static let stallTimeout: Double = 6.0

    // Windowed observability counters + 5 s heartbeat timer.
    private let stats = ProbeStats()
    private var statTimer: DispatchSourceTimer?

    var isConnected: Bool { connection != nil }

    private func publish(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func mark(_ s: String) { publish { self.step = s } }

    // Last connected interface, kept so the no-data watchdog can reconnect.
    private var lastInterface: String = ""
    private var lastReconnect = Date.distantPast
    private var reconnectPending = false
    private var waitConfigWarnCount = 0

    func connect(interface: String) {
        lastInterface = interface
        awaitingKeyframe = true
        waitConfigWarnCount = 0
        DiagLog.shared.reset()
        DiagLog.shared.evt("connect start iface=\(interface)")
        disconnect()
        startStatTimer()
        wanted = true
        generation += 1
        let gen = generation
        Self.active = self
        publish {
            self.status = "连接 fe80::2%\(interface):7101 …"
            self.detail = ""
            self.lastError = ""
        }
        establish(interface: interface, gen: gen, attempt: 0)
    }

    /// The 7101 push server is started together with the CarPlay session and can be
    /// briefly unavailable (ECONNABORTED / errno 53) right after a reconnect. Retry a
    /// few times so the user doesn't have to time the tap perfectly.
    private func establish(interface: String, gen: Int, attempt: Int) {
        guard gen == self.generation, self.wanted else { return }
        let maxAttempts = 6
        mark(attempt == 0 ? "解析端点" : "重试连接 \(attempt)/\(maxAttempts - 1)")
        guard let port = NWEndpoint.Port(rawValue: 7101) else {
            publish { self.lastError = "端口无效" }
            return
        }
        let host = NWEndpoint.Host("fe80::2%\(interface)")
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        mark("创建连接 \(attempt)")
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.publish {
                guard gen == self.generation, self.wanted else { return }
                switch state {
                case .ready:
                    DiagLog.shared.evt("TCP ready attempt=\(attempt) gen=\(gen)")
                    self.reconnectPending = false
                    self.lastError = ""
                    self.status = "已连接，等待关键帧"
                    self.mark("ready - waiting IDR")
                    self.awaitingKeyframe = true
                    self.clearBuffer()
                    self.receiveMore()
                    // Start the no-data watchdog now; it is rearmed by every
                    // received chunk. Reconnects if the stream silently stops.
                    self.armStallWatchdog(gen: gen)
                case .waiting(let err):
                    self.status = "等待网络"
                    self.detail = "\(err)"
                    self.mark("waiting: \(err)")
                case .failed(let err):
                    DiagLog.shared.warn("TCP failed attempt=\(attempt) gen=\(gen) err=\(err)")
                    self.teardownConnection()
                    if attempt + 1 < maxAttempts {
                        self.mark("连接失败，1 秒后重试：\(err)")
                        let delay = DispatchTime.now() + 1.0
                        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
                            self?.establish(interface: interface, gen: gen, attempt: attempt + 1)
                        }
                    } else {
                        self.reconnectPending = false
                        self.awaitingKeyframe = true
                        self.lastError = "连接失败（已重试 \(attempt) 次）：\(err)"
                        self.status = "失败"
                        self.mark("failed: \(err)")
                    }
                case .cancelled:
                    self.status = "已断开"
                default:
                    break
                }
            }
        }
        mark("启动连接 \(attempt)")
        conn.start(queue: readQueue)
    }

    func disconnect() {
        wanted = false
        generation += 1
        reconnectPending = false
        stopStatTimer()
        if let line = stats.flush() { DiagLog.shared.stat(line) }
        teardownConnection()
        Self.active = nil
        DiagLog.shared.evt("disconnect")
        publish { self.status = "未连接" }
    }

    private func teardownConnection() {
        stallWorkItem?.cancel()
        stallWorkItem = nil
        connection?.cancel()
        connection = nil
        if let s = session {
            VTDecompressionSessionInvalidate(s)
            session = nil
        }
        formatDesc = nil
        frameIndex = 0
        submitted = 0
        callbackCount = 0
        pendingImage = nil
        awaitingKeyframe = true
        lastKeyframeType = ""
        codecByte = 0
        clearBuffer()
    }

    /// All readBuffer mutations must happen on readQueue. Combined with the
    /// [UInt8] backing store this removes both the cross-thread race and the
    /// Data.startIndex drift that caused two separate out-of-bounds traps.
    private func clearBuffer() {
        readQueue.async { self.readBuffer.removeAll(keepingCapacity: true) }
    }

    deinit {
        connection?.cancel()
        if let s = session { VTDecompressionSessionInvalidate(s) }
    }

    private func receiveMore() {
        guard let conn = connection else { return }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.stats.chunk(data.count)
                self.readQueue.async {
                    self.readBuffer.append(contentsOf: data)
                    self.parseFrames()
                    // Any inbound data means the stream is alive — rearm watchdog.
                    self.armStallWatchdog(gen: self.generation)
                }
            }
            if let error {
                DiagLog.shared.warn("recv error gen=\(self.generation) err=\(error)")
                self.publish { self.lastError = "收流错误：\(error)" }
                return
            }
            if isComplete {
                DiagLog.shared.evt("recv isComplete gen=\(self.generation) (peer closed)")
                self.publish {
                    self.status = "对端关闭"
                    self.teardownConnection()
                }
                return
            }
            self.receiveMore()
        }
    }

    private func parseFrames() {
        let headerSize = 10
        while readBuffer.count >= headerSize {
            // Resync to the "NPVS" magic; array indices are always 0-based.
            guard readBuffer[0] == 0x4E, readBuffer[1] == 0x50,
                  readBuffer[2] == 0x56, readBuffer[3] == 0x53 else {
                readBuffer.removeFirst()
                stats.didResync()
                continue
            }
            let kind = readBuffer[4]
            let codec = readBuffer[5]
            // Big-endian 32-bit length. UInt8 -> Int shift is safe on 64-bit.
            let length = (Int(readBuffer[6]) << 24) | (Int(readBuffer[7]) << 16) |
                         (Int(readBuffer[8]) << 8) | Int(readBuffer[9])
            guard length <= 32 * 1024 * 1024 else {
                readBuffer.removeAll(keepingCapacity: true)
                stats.badLength()
                DiagLog.shared.warn("badLen len=\(length) buf=\(readBuffer.count) resynced")
                publish { self.lastError = "帧长度异常：\(length)，已重新同步" }
                return
            }
            let total = headerSize + length
            guard readBuffer.count >= total else { break }  // wait for rest of frame
            let body = Array(readBuffer[headerSize..<total])
            readBuffer.removeFirst(total)
            stats.parsed(kind: kind)
            if kind == 1 {
                mark("解析配置帧 \(length)B")
                applyConfig(codec: codec, data: Data(body))
            } else if kind == 2 {
                mark("解析视频帧 \(length)B")
                submitFrame(Data(body))
            }
        }
    }

    private func applyConfig(codec: UInt8, data: Data) {
        DiagLog.shared.evt("CONFIG codec=\(codec) bytes=\(data.count)")
        mark("apply config \(data.count)B")
        codecByte = codec
        // H264 avcC keeps lengthSizeMinusOne at byte 4; H265 hvcC keeps it at
        // byte 21. Reading byte 4 for hvcC returns profile flags -> bogus size 1.
        nalLengthSize = Self.nalLengthSize(from: data, codec: codec)
        guard let desc = Self.formatDescription(from: data, codec: codec) else {
            stats.config(applied: false)
            DiagLog.shared.warn("CONFIG fail codec=\(codec) bytes=\(data.count) fmtDesc=nil")
            publish { self.lastError = "无法从配置帧构造格式描述" }
            return
        }
        stats.config(applied: true)
        formatDesc = desc
        mark("format desc ok - create session")
        recreateSession()
        DiagLog.shared.evt("CONFIG applied codec=\(codec) nalLen=\(nalLengthSize) session=\(session != nil)")
        if session != nil {
            publish {
                self.detail = "配置：\(codec == 1 ? "H265" : "H264")，NAL 长度 \(self.nalLengthSize) 字节"
            }
            mark("session ready")
        }
    }

    private static func formatDescription(from data: Data, codec: UInt8) -> CMFormatDescription? {
        let b = [UInt8](data)
        var arrays: [[UInt8]] = []
        if codec == 0 {
            guard b.count > 6 else { return nil }
            let numSPS = Int(b[5] & 0x1F)
            var p = 6
            for _ in 0..<numSPS {
                guard p + 2 <= b.count else { break }
                let len = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                guard p + len <= b.count else { break }
                arrays.append(Array(b[p..<(p + len)])); p += len
            }
            guard p < b.count else { return nil }
            let numPPS = Int(b[p]); p += 1
            for _ in 0..<numPPS {
                guard p + 2 <= b.count else { break }
                let len = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                guard p + len <= b.count else { break }
                arrays.append(Array(b[p..<(p + len)])); p += len
            }
        } else {
            guard b.count > 22 else { return nil }
            let numArrays = Int(b[22]); var p = 23
            for _ in 0..<numArrays {
                guard p + 3 <= b.count else { break }
                p += 1
                let numNalus = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                for _ in 0..<numNalus {
                    guard p + 2 <= b.count else { break }
                    let len = Int(b[p]) << 8 | Int(b[p + 1]); p += 2
                    guard p + len <= b.count else { break }
                    arrays.append(Array(b[p..<(p + len)])); p += len
                }
            }
        }
        guard !arrays.isEmpty else { return nil }

        var contiguous = Data()
        var offsets: [(Int, Int)] = []
        for a in arrays {
            offsets.append((contiguous.count, a.count))
            contiguous.append(contentsOf: a)
        }
        let headerLength = Int32(Self.nalLengthSize(from: data, codec: codec))
        // NSData keeps the backing bytes alive for the whole API call.
        let storage = contiguous as NSData
        let base = storage.bytes.assumingMemoryBound(to: UInt8.self)
        var pointers: [UnsafePointer<UInt8>] = offsets.map { base + $0.0 }
        let sizes = offsets.map { $0.1 }
        var out: CMFormatDescription?
        pointers.withUnsafeMutableBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                guard let ptr = pp.baseAddress, let sz = ss.baseAddress else { return }
                if codec == 0 {
                    _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: offsets.count,
                        parameterSetPointers: UnsafePointer(ptr),
                        parameterSetSizes: sz,
                        nalUnitHeaderLength: headerLength,
                        formatDescriptionOut: &out
                    )
                } else {
                    _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: offsets.count,
                        parameterSetPointers: UnsafePointer(ptr),
                        parameterSetSizes: sz,
                        nalUnitHeaderLength: headerLength,
                        extensions: nil,
                        formatDescriptionOut: &out
                    )
                }
            }
        }
        return out
    }

    /// avcC (H264): lengthSizeMinusOne lives at byte 4 (after 4-byte header).
    /// hvcC (H265): configurationVersion(1) + general_profile/tier(1) +
    /// compatibility(4) + constraint(6) + level(1) = 13, then reserved/minSpatial(2),
    /// reserved/parallelism(1), reserved/chroma(1), reserved/lumaDepth(1),
    /// reserved/chromaDepth(1), avgFrameRate(2) = 21 bytes, then the byte whose
    /// low 2 bits are lengthSizeMinusOne at offset 21.
    private static func nalLengthSize(from data: Data, codec: UInt8) -> Int {
        let offset = codec == 1 ? 21 : 4
        guard data.count > offset else { return 4 }
        let v = Int(data[offset] & 0x03) + 1
        return (v >= 1 && v <= 4) ? v : 4
    }

    private func recreateSession() {
        if let s = session { VTDecompressionSessionInvalidate(s); session = nil }
        guard let desc = formatDesc else { return }
        var record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: outputCallback,
            decompressionOutputRefCon: nil
        )
        let opts: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey as CFString: kCVPixelFormatType_32BGRA
        ]
        let st = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: desc,
            decoderSpecification: nil,
            imageBufferAttributes: opts as CFDictionary,
            outputCallback: &record,
            decompressionSessionOut: &session
        )
        if st != noErr { publish { self.lastError = "解码器创建失败：\(st)" } }
    }

    private let outputCallback: VTDecompressionOutputCallback = { _, _, status, _, image, _, _ in
        let code = status
        guard let tester = VideoPreviewTester.active else { return }
        DispatchQueue.main.async {
            tester.callbackCount += 1
            if code != noErr || image == nil {
                tester.stats.decoded(ok: false)
                // IDR-driven recovery: a decode failure means the reference chain
                // is broken. Do NOT reconnect (there is no server GOP to replay any
                // more) and do NOT flash stale frames — just drop this frame and
                // go back to waiting for the next IDR, which rebuilds the session.
                // This callback runs on main; flip the flag on readQueue so it is
                // serialized with submitFrame's state access.
                DiagLog.shared.warn("decodeFail status=\(code) -> await keyframe")
                tester.readQueue.async {
                    guard tester.wanted else { return }
                    tester.awaitingKeyframe = true
                }
                return
            }
            tester.stats.decoded(ok: true)
            guard let image else { return }
            // Coalesce: callbacks only overwrite the newest-frame slot. One
            // refresh is scheduled; when the main queue drains (e.g. back from
            // background) only the latest frame is shown, not every stale one.
            tester.pendingImage = image
            if !tester.displayRefreshScheduled {
                tester.displayRefreshScheduled = true
                DispatchQueue.main.async {
                    tester.displayRefreshScheduled = false
                    guard let newest = tester.pendingImage else { return }
                    tester.pendingImage = nil
                    tester.latestImage = newest
                    tester.decodedFrames += 1
                    tester.stats.didShow()
                }
            }
        }
    }

    /// Emit a PROBE-STAT heartbeat every 5 s for the whole connection lifetime.
    private func startStatTimer() {
        stopStatTimer()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let line = self?.stats.flush() else { return }
            DiagLog.shared.stat(line)
        }
        t.resume()
        statTimer = t
    }

    private func stopStatTimer() {
        statTimer?.cancel()
        statTimer = nil
    }

    /// (Re)arm the no-data watchdog. Called on every received chunk and once
    /// right after TCP ready. If nothing arrives within the timeout, reconnect.
    private func armStallWatchdog(gen: Int) {
        stallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.wanted else { return }
            DiagLog.shared.warn("stall noData=\(Self.stallTimeout)s gen=\(gen) -> reconnect")
            self.reconnectForRecovery(reason: "stall")
        }
        stallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stallTimeout, execute: item)
    }

    /// Silent reconnect (keeps the diagnostic log) used only by the no-data
    /// watchdog now. On reconnect the server sends config and asks the iPhone for
    /// a fresh IDR; we start decoding when that IDR arrives.
    private func reconnectForRecovery(reason: String = "stall") {
        guard wanted, !lastInterface.isEmpty, !reconnectPending else { return }
        let now = Date()
        // Stall (no data) respects a cooldown; invalidSession (-12903) bypasses it
        // because it often fires just seconds after a prior reconnect yet is the
        // only way to get a fresh session + IDR. reconnectPending prevents a burst
        // of -12903 frames from stacking up reconnects.
        if reason != "invalidSession" && now.timeIntervalSince(lastReconnect) < 8 { return }
        lastReconnect = now
        reconnectPending = true
        DiagLog.shared.evt("autoReconnect reason=\(reason) gen=\(generation)")
        stats.didReconnect()
        stallWorkItem?.cancel()
        stallWorkItem = nil
        generation += 1
        let gen = generation
        teardownConnection()
        Self.active = self
        publish { self.status = "重连中…" }
        // Brief pause so the server drops the old socket before we reconnect.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, gen == self.generation, self.wanted else { return }
            self.establish(interface: self.lastInterface, gen: gen, attempt: 0)
        }
    }

    private func submitFrame(_ annexb: Data) {
        // If the one-shot config frame was missed (client connected late), try to
        // build a decoder from SPS/PPS embedded in the stream itself. Harmless if
        // the frame has none — we simply keep waiting for a real config frame.
        if formatDesc == nil { _ = tryAdoptConfigFromFrame(annexb) }
        guard let desc = formatDesc, self.session != nil else {
            let kinds = Self.naluTypeSummary(annexb)
            waitConfigWarnCount += 1
            if waitConfigWarnCount == 1 || waitConfigWarnCount % 100 == 0 {
                DiagLog.shared.warn("waitConfig n=\(waitConfigWarnCount) bytes=\(annexb.count) \(kinds)")
            }
            publish { self.detail = "等配置帧…（已收 \(annexb.count) 字节，NALU: \(kinds)）" }
            return
        }
        waitConfigWarnCount = 0
        let kinds = Self.naluTypeSummary(annexb)

        // IDR-driven gate: while waiting for a keyframe, drop every non-IDR frame.
        // A P frame without its reference IDR decodes to -12909/-17694 and, worse,
        // poisons the reference chain. We keep the last displayed image (freeze)
        // instead. When an IDR arrives, rebuild the session so the chain starts clean.
        let isKey = Self.isKeyframe(annexb, codec: codecByte)
        if awaitingKeyframe {
            if !isKey {
                stats.dropped(noIdr: true)
                publish { self.detail = "等 IDR…（已丢弃 \(annexb.count)B 非关键帧）" }
                return
            }
            // First IDR of a new chain: reset the decoder so no stale references
            // from the pre-join stream can poison this GOP.
            DiagLog.shared.evt("IDR detected \(kinds) bytes=\(annexb.count) -> start decode")
            stats.idr()
            lastKeyframeType = kinds
            awaitingKeyframe = false
            recreateSession()
            guard self.session != nil else {
                DiagLog.shared.warn("IDR session recreate failed -> await keyframe")
                awaitingKeyframe = true
                return
            }
            mark("IDR - decoding")
        } else if isKey {
            // A new IDR mid-stream is a clean GOP boundary; log it but keep the
            // session (VideoToolbox handles in-band IDR as a reference reset).
            stats.idr()
            lastKeyframeType = kinds
            DiagLog.shared.line("TRACE idr midstream \(kinds) bytes=\(annexb.count)")
        }

        let prefixed = Self.annexBToLengthPrefixed(annexb, lengthSize: nalLengthSize)
        guard !prefixed.isEmpty else {
            stats.transcoded(empty: true)
            DiagLog.shared.warn("transEmpty raw=\(annexb.count) \(kinds)")
            return
        }
        stats.transcoded(empty: false)

        // Allocate block buffer memory owned by the buffer, then copy bytes in.
        var block: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: prefixed.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: prefixed.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard createStatus == noErr, let block else {
            publish { self.lastError = "块缓冲分配失败：\(createStatus)" }
            return
        }
        let copyStatus = prefixed.withUnsafeBytes { raw -> OSStatus in
            guard let src = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: src,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: prefixed.count
            )
        }
        guard copyStatus == noErr else {
            publish { self.lastError = "块缓冲写入失败：\(copyStatus)" }
            return
        }

        var sample: CMSampleBuffer?
        frameIndex += 1
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: frameIndex, timescale: 30),
            decodeTimeStamp: .invalid
        )
        var size = prefixed.count
        let sst = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: desc,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard sst == noErr, let sample else {
            publish { self.lastError = "采样缓冲创建失败：\(sst)" }
            return
        }
        // Re-read self.session: the IDR gate above may have rebuilt it, and the
        // `session` bound by the earlier guard is a stale snapshot of the old one.
        guard let decodeSession = self.session else { return }
        let dst = VTDecompressionSessionDecodeFrame(
            decodeSession,
            sampleBuffer: sample,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        submitted += 1
        lastDecodeStatus = dst
        stats.didSubmit(ok: dst == noErr)
        // TRACE: sample one frame per second instead of every frame, so a long
        // session does not flood the log. Full counts live in PROBE-STAT.
        if submitted % 30 == 0 || dst != noErr {
            DiagLog.shared.line("TRACE frame#\(submitted) \(kinds) bytes=\(prefixed.count) decode=\(dst) cb=\(callbackCount)")
        }
        if dst != noErr {
            DiagLog.shared.warn("decodeSubmitFail status=\(dst) frame#\(submitted)")
            // kVTInvalidSessionErr (-12903): after the app returns from background,
            // VideoToolbox invalidates the session. Unlike a bad-data error (-12909),
            // the session itself is dead — every subsequent submit fails and no callback
            // ever fires, so the decode-callback path can't detect it. The no-data
            // watchdog can't help either (TCP keeps streaming). Rebuild the session
            // right here and go back to waiting for an IDR, so the next keyframe
            // starts a fresh chain on a live decoder instead of freezing for 20+s.
            if dst == -12903 {
                // A bare local session rebuild is not enough: the iPhone won't send
                // a fresh IDR on demand (static screen may stay on P frames for ages),
                // so we'd freeze waiting. A reconnect does BOTH — new session AND a
                // fresh IDR (the server issues forceKeyFrame on client connect), which
                // is exactly how the log shows the stream recovering every time.
                DiagLog.shared.warn("invalidSession -12903 -> reconnect for fresh IDR")
                awaitingKeyframe = true
                reconnectForRecovery(reason: "invalidSession")
                publish { self.lastError = "解码会话失效，重连中…" }
            } else {
                publish { self.lastError = "解码失败：\(dst)" }
            }
        }
    }

    /// Split an Annex-B stream into raw NALUs (without start codes).
    private static func splitAnnexB(_ data: Data) -> [[UInt8]] {
        let b = [UInt8](data)
        var nalus: [[UInt8]] = []
        var i = 0
        func startCodeLen(_ idx: Int) -> Int {
            if idx + 3 < b.count, b[idx] == 0, b[idx + 1] == 0, b[idx + 2] == 0, b[idx + 3] == 1 { return 4 }
            if idx + 2 < b.count, b[idx] == 0, b[idx + 1] == 0, b[idx + 2] == 1 { return 3 }
            return 0
        }
        while i < b.count, startCodeLen(i) == 0 { i += 1 }
        while i < b.count {
            let sc = startCodeLen(i)
            if sc == 0 { break }
            let start = i + sc
            var end = b.count
            var j = start
            while j + 2 < b.count {
                if startCodeLen(j) > 0 { end = j; break }
                j += 1
            }
            if end > start { nalus.append(Array(b[start..<end])) }
            i = end
        }
        return nalus
    }

    /// True if any NALU in this (Annex-B) frame is a random-access point:
    /// H264 IDR = type 5; H265 IDR/IRAP = type 16...21 (matches DiPlay's
    /// MediaCodecSupport.isRandomAccess). Used to gate decoding so we never feed
    /// a reference-less P frame to VideoToolbox.
    private static func isKeyframe(_ data: Data, codec: UInt8) -> Bool {
        for n in splitAnnexB(data) {
            guard let h = n.first else { continue }
            if codec == 1 {
                let t = Int((h >> 1) & 0x3F)
                if t >= 16 && t <= 21 { return true }
            } else {
                let t = Int(h & 0x1F)
                if t == 5 { return true }
            }
        }
        return false
    }

    /// Human-readable NALU type list for diagnostics (H264: type = byte0 & 0x1F;
    /// H265: type = (byte0 >> 1) & 0x3F).
    private static func naluTypeSummary(_ data: Data) -> String {
        let nalus = splitAnnexB(data)
        guard !nalus.isEmpty else { return "无起始码" }
        return nalus.prefix(6).map { n -> String in
            guard let h = n.first else { return "?" }
            let t264 = Int(h & 0x1F)
            let t265 = Int((h >> 1) & 0x3F)
            return "264t\(t264)/265t\(t265)"
        }.joined(separator: ",")
    }

    /// Last-resort config recovery: if we never saw a config frame, look for
    /// in-band VPS/SPS/PPS NALUs (some encoders repeat them on keyframes) and
    /// build a CMFormatDescription from those. Returns true on success.
    private func tryAdoptConfigFromFrame(_ annexb: Data) -> Bool {
        let nalus = Self.splitAnnexB(annexb)
        var vps: [[UInt8]] = [], sps: [[UInt8]] = [], pps: [[UInt8]] = []
        var isHEVC = false
        for n in nalus {
            guard let h = n.first else { continue }
            let t264 = Int(h & 0x1F)
            let t265 = Int((h >> 1) & 0x3F)
            if t265 == 32 { isHEVC = true; vps.append(n) }
            else if t265 == 33 { isHEVC = true; sps.append(n) }
            else if t265 == 34 { isHEVC = true; pps.append(n) }
            else if t264 == 7 && !isHEVC { sps.append(n) }
            else if t264 == 8 && !isHEVC { pps.append(n) }
        }
        guard !sps.isEmpty, !pps.isEmpty else { return false }
        let sets = (isHEVC ? vps : []) + sps + pps
        var contiguous = Data()
        var offsets: [(Int, Int)] = []
        for s in sets {
            offsets.append((contiguous.count, s.count))
            contiguous.append(contentsOf: s)
        }
        let headerLength = Int32(nalLengthSize)
        let storage = contiguous as NSData
        let base = storage.bytes.assumingMemoryBound(to: UInt8.self)
        var pointers: [UnsafePointer<UInt8>] = offsets.map { base + $0.0 }
        let sizes = offsets.map { $0.1 }
        var out: CMFormatDescription?
        pointers.withUnsafeMutableBufferPointer { pp in
            sizes.withUnsafeBufferPointer { ss in
                guard let ptr = pp.baseAddress, let sz = ss.baseAddress else { return }
                if isHEVC {
                    _ = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: UnsafePointer(ptr),
                        parameterSetSizes: sz,
                        nalUnitHeaderLength: headerLength,
                        extensions: nil,
                        formatDescriptionOut: &out
                    )
                } else {
                    _ = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: UnsafePointer(ptr),
                        parameterSetSizes: sz,
                        nalUnitHeaderLength: headerLength,
                        formatDescriptionOut: &out
                    )
                }
            }
        }
        guard let desc = out else { return false }
        formatDesc = desc
        codecByte = isHEVC ? 1 : 0
        recreateSession()
        if session != nil {
            publish { self.detail = "已从帧内参数集恢复解码（\(isHEVC ? "H265" : "H264")）" }
        }
        return session != nil
    }

    private static func annexBToLengthPrefixed(_ data: Data, lengthSize: Int) -> Data {
        // Reuse splitAnnexB. The previous inline parser initialized end=start, so
        // when a frame had no further start code it kept end==start and hit
        // `end <= start { break }`, silently dropping the final NALU — for a
        // single-NALU frame that discarded the entire picture, leaving frame 0.
        // splitAnnexB extends the last NALU to the end of the buffer correctly.
        let nalus = splitAnnexB(data)
        // If no Annex-B start code was found, the payload is already length-prefixed
        // (AVCC/HVCC) — pass it through unchanged instead of returning empty. This
        // keeps decoding working even if a server sends the other framing format.
        if nalus.isEmpty { return data }
        var out = Data()
        for nalu in nalus {
            let len = nalu.count
            if lengthSize == 4 {
                out.append(UInt8((len >> 24) & 0xFF)); out.append(UInt8((len >> 16) & 0xFF))
                out.append(UInt8((len >> 8) & 0xFF)); out.append(UInt8(len & 0xFF))
            } else {
                for k in (0..<lengthSize).reversed() { out.append(UInt8((len >> (k * 8)) & 0xFF)) }
            }
            out.append(contentsOf: nalu)
        }
        return out
    }
}
