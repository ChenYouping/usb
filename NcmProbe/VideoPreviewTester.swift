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

    /// The VT callback gets an opaque refCon; using a weak static avoids the
    /// dangling-pointer risk of Unmanaged.passUnretained after invalidation.
    private weak static var active: VideoPreviewTester?

    private var connection: NWConnection?
    private var session: VTDecompressionSession?
    private var formatDesc: CMFormatDescription?
    private var nalLengthSize: Int = 4
    private var readBuffer = Data()
    private let readQueue = DispatchQueue(label: "npvs.read", qos: .userInitiated)

    private var wanted = false
    private var generation = 0

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
        mark("resolve endpoint")
        guard let port = NWEndpoint.Port(rawValue: 7101) else {
            publish { self.lastError = "端口无效" }
            return
        }
        let host = NWEndpoint.Host("fe80::2%\(interface)")
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        mark("create connection")
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.publish {
                guard gen == self.generation, self.wanted else { return }
                switch state {
                case .ready:
                    self.status = "已连接，等待首帧"
                    self.mark("ready - waiting frame")
                    self.clearBuffer()
                    self.receiveMore()
                case .waiting(let err):
                    self.status = "等待网络"
                    self.detail = "\(err)"
                    self.mark("waiting: \(err)")
                case .failed(let err):
                    self.lastError = "连接失败：\(err)"
                    self.status = "失败"
                    self.mark("failed: \(err)")
                    self.teardownConnection()
                case .cancelled:
                    self.status = "已断开"
                default:
                    break
                }
            }
        }
        mark("start connection")
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
        clearBuffer()
    }

    /// All readBuffer mutations must happen on readQueue. This prevents the
    /// cross-thread race between the main thread (teardown/ready) and the
    /// receive queue (append/parse) that caused an out-of-bounds trap.
    private func clearBuffer() {
        readQueue.async { self.readBuffer.removeAll() }
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
                    self.readBuffer.append(data)
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
            guard readBuffer[0] == 0x4E, readBuffer[1] == 0x50,
                  readBuffer[2] == 0x56, readBuffer[3] == 0x53 else {
                readBuffer.removeFirst()
                continue
            }
            let kind = readBuffer[4]
            let codec = readBuffer[5]
            let length = Int(readBuffer[6]) << 24 | Int(readBuffer[7]) << 16 |
                         Int(readBuffer[8]) << 8  | Int(readBuffer[9])
            guard length >= 0, length <= 32 * 1024 * 1024 else {
                readBuffer.removeAll()
                return
            }
            guard readBuffer.count >= headerSize + length else { break }
            let body = Data(readBuffer[headerSize..<(headerSize + length)])
            readBuffer.removeFirst(headerSize + length)
            // Already on readQueue; call directly so buffer work stays serialized.
            if kind == 1 {
                applyConfig(codec: codec, data: body)
            } else if kind == 2 {
                submitFrame(body)
            }
        }
    }

    private func applyConfig(codec: UInt8, data: Data) {
        mark("apply config \(data.count)B")
        if data.count > 4 { nalLengthSize = Int(data[4] & 0x03) + 1 }
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
        let headerLength = Int32(nalLengthSizeFrom(data))
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

    private static func nalLengthSizeFrom(_ data: Data) -> Int {
        guard data.count > 4 else { return 4 }
        return Int(data[4] & 0x03) + 1
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
        guard status == noErr, let image else { return }
        guard let tester = VideoPreviewTester.active else { return }
        if Thread.isMainThread {
            tester.latestImage = image
            tester.decodedFrames += 1
        } else {
            DispatchQueue.main.async {
                tester.latestImage = image
                tester.decodedFrames += 1
            }
        }
    }

    private func submitFrame(_ annexb: Data) {
        guard let desc = formatDesc, let session else {
            publish { self.detail = "等配置帧…（已收 \(annexb.count) 字节）" }
            return
        }
        let prefixed = Self.annexBToLengthPrefixed(annexb, lengthSize: nalLengthSize)
        guard !prefixed.isEmpty else { return }

        // Allocate block buffer memory owned by the buffer, then copy bytes in.
        // The old version pointed at a temporary Data buffer (use-after-free).
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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: Int64(decodedFrames), timescale: 30),
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
        if dst != noErr { publish { self.lastError = "解码失败：\(dst)" } }
    }

    private static func annexBToLengthPrefixed(_ data: Data, lengthSize: Int) -> Data {
        let b = [UInt8](data)
        var nalus: [[UInt8]] = []
        var i = 0
        func scLen(_ idx: Int) -> Int {
            if idx + 3 < b.count, b[idx] == 0, b[idx + 1] == 0, b[idx + 2] == 0, b[idx + 3] == 1 { return 4 }
            if idx + 2 < b.count, b[idx] == 0, b[idx + 1] == 0, b[idx + 2] == 1 { return 3 }
            return 0
        }
        while i < b.count, scLen(i) == 0 { i += 1 }
        while i < b.count {
            let sc = scLen(i)
            if sc == 0 { break }
            let start = i + sc
            var end = start
            var next = start
            while next + 2 < b.count {
                if scLen(next) > 0 { end = next; break }
                next += 1
            }
            if end <= start { break }
            nalus.append(Array(b[start..<end]))
            i = end
        }
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
