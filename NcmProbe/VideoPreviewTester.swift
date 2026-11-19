import Foundation
import Network
import VideoToolbox
import CoreMedia
import CoreVideo

/// Receives the NPVS stream from DiPlay's VideoFrameRelay (port 7101) and decodes
/// the Annex-B H.264/H.265 frames with VideoToolbox into CVPixelBuffers.
final class VideoPreviewTester: ObservableObject {
    @Published private(set) var status = "未连接"
    @Published private(set) var detail = ""
    @Published private(set) var decodedFrames = 0
    @Published private(set) var lastError = ""
    @Published private(set) var latestImage: CVPixelBuffer?
    @Published private(set) var step = "idle"
    /// Decode diagnostics: frames submitted, decode return codes, callback status.
    @Published private(set) var decodeDiag = ""

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
    @Published private(set) var callbackCount = 0
    @Published private(set) var lastCallback = ""

    var isConnected: Bool { connection != nil }

    private func publish(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func mark(_ s: String) { publish { self.step = s } }

    func connect(interface: String) {
        disconnect()
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
                    self.lastError = ""
                    self.status = "已连接，等待首帧"
                    self.mark("ready - waiting frame")
                    self.clearBuffer()
                    self.receiveMore()
                case .waiting(let err):
                    self.status = "等待网络"
                    self.detail = "\(err)"
                    self.mark("waiting: \(err)")
                case .failed(let err):
                    self.teardownConnection()
                    if attempt + 1 < maxAttempts {
                        self.mark("连接失败，1 秒后重试：\(err)")
                        let delay = DispatchTime.now() + 1.0
                        DispatchQueue.main.asyncAfter(deadline: delay) { [weak self] in
                            self?.establish(interface: interface, gen: gen, attempt: attempt + 1)
                        }
                    } else {
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
        teardownConnection()
        Self.active = nil
        publish { self.status = "未连接" }
    }

    private func teardownConnection() {
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
        lastCallback = ""
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
                self.readQueue.async {
                    self.readBuffer.append(contentsOf: data)
                    self.parseFrames()
                }
            }
            if let error {
                self.publish { self.lastError = "收流错误：\(error)" }
                return
            }
            if isComplete {
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
                continue
            }
            let kind = readBuffer[4]
            let codec = readBuffer[5]
            // Big-endian 32-bit length. UInt8 -> Int shift is safe on 64-bit.
            let length = (Int(readBuffer[6]) << 24) | (Int(readBuffer[7]) << 16) |
                         (Int(readBuffer[8]) << 8) | Int(readBuffer[9])
            guard length <= 32 * 1024 * 1024 else {
                readBuffer.removeAll(keepingCapacity: true)
                publish { self.lastError = "帧长度异常：\(length)，已重新同步" }
                return
            }
            let total = headerSize + length
            guard readBuffer.count >= total else { break }  // wait for rest of frame
            let body = Array(readBuffer[headerSize..<total])
            readBuffer.removeFirst(total)
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
        mark("apply config \(data.count)B")
        // H264 avcC keeps lengthSizeMinusOne at byte 4; H265 hvcC keeps it at
        // byte 21. Reading byte 4 for hvcC returns profile flags -> bogus size 1.
        nalLengthSize = Self.nalLengthSize(from: data, codec: codec)
        guard let desc = Self.formatDescription(from: data, codec: codec) else {
            publish { self.lastError = "无法从配置帧构造格式描述" }
            return
        }
        formatDesc = desc
        mark("format desc ok - create session")
        recreateSession()
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
        let hasImage = image != nil
        guard let tester = VideoPreviewTester.active else { return }
        DispatchQueue.main.async {
            tester.callbackCount += 1
            tester.lastCallback = "回调#\(tester.callbackCount) status=\(code) 图像=\(hasImage)"
            guard code == noErr, let image else { return }
            tester.latestImage = image
            tester.decodedFrames += 1
        }
    }

    private func submitFrame(_ annexb: Data) {
        // If the one-shot config frame was missed (client connected late), try to
        // build a decoder from SPS/PPS embedded in the stream itself. Harmless if
        // the frame has none — we simply keep waiting for a real config frame.
        if formatDesc == nil { _ = tryAdoptConfigFromFrame(annexb) }
        guard let desc = formatDesc, let session else {
            let kinds = Self.naluTypeSummary(annexb)
            publish { self.detail = "等配置帧…（已收 \(annexb.count) 字节，NALU: \(kinds)）" }
            return
        }
        let kinds = Self.naluTypeSummary(annexb)
        let prefixed = Self.annexBToLengthPrefixed(annexb, lengthSize: nalLengthSize)
        guard !prefixed.isEmpty else {
            publish { self.decodeDiag = "帧转码后为空（\(kinds)）" }
            return
        }

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
        let dst = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: nil
        )
        submitted += 1
        lastDecodeStatus = dst
        let sub = submitted, cb = callbackCount, st = dst
        publish {
            self.decodeDiag = "已送解码 \(sub) 帧 / 回调 \(cb) 次 / 上次 decode=\(st) / 帧头 \(kinds)"
        }
        if dst != noErr { publish { self.lastError = "解码失败：\(dst)" } }
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
