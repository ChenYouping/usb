import Foundation
import Darwin
import Network

/// Lightweight error so Result's Failure type conforms to Error while keeping
/// plain string interpolation (`\(msg)`) readable in the log.
private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Raw TCP throughput tester against DiPlay's DiplayTcpChannel (port 7100).
///
/// Wire protocol (must match the DiPlay side):
///   request : "NPCM" (4 bytes ASCII) + op UInt8 + length Int32 BE + body
///   response: "NPCK" (4 bytes ASCII) + status UInt8 + length Int32 BE + body
/// op 1 = ECHO (server returns the exact body), op 2 = INFO (server returns a text line).
///
/// The tester opens one connection and sends a series of ECHO payloads of increasing size,
/// measuring wall-clock round-trip time for each and deriving throughput. It settles at most
/// once per run and uses a token check so a stale run cannot overwrite a newer one.
final class TcpChannelTester: ObservableObject {
    @Published var log: String = "尚未测试"
    @Published var isRunning: Bool = false

    private var connection: NWConnection?
    private var runToken: UInt64 = 0

    private static let diPlayAddress = "fe80::2"
    private static let port: UInt16 = 7100
    private static let magicRequest: [UInt8] = Array("NPCM".utf8)
    private static let magicResponse: [UInt8] = Array("NPCK".utf8)
    private static let opEcho: UInt8 = 1
    private static let timeoutSeconds: Double = 5.0

    /// Payload sizes exercised in one run. Larger sizes amortize RTT and approach link throughput.
    private static let payloadSizes = [1024, 16 * 1024, 64 * 1024, 256 * 1024]

    func run(interface: String) {
        cancel()
        let iface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = iface.isEmpty ? Self.diPlayAddress : "\(Self.diPlayAddress)%\(iface)"

        guard iface.isEmpty || if_nametoindex(iface) != 0 else {
            log = "找不到接口 \(iface)，先在「判定结果」里确认 NCM 接口名"
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: Self.port) else { return }

        runToken += 1
        let token = runToken
        isRunning = true
        log = "连接 \(host):\(Self.port) 并准备测速 …\n"

        let settled = NSLock()
        var didSettle = false
        let finish: (String) -> Void = { text in
            settled.lock()
            if didSettle { settled.unlock(); return }
            didSettle = true
            settled.unlock()
            DispatchQueue.main.async {
                guard token == self.runToken else { return }
                self.isRunning = false
                self.log = text
            }
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        let queue = DispatchQueue(label: "ncmprobe.tcpchannel")

        DispatchQueue.global().asyncAfter(deadline: .now() + 30.0) {
            finish("timeout：30 秒内未完成测速。确认 DiPlay 是带 TCP 通道的版本、CarPlay 已出画面。")
        }

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.performEchoSeries(on: conn, queue: queue, token: token, finish: finish)
            case .failed(let error):
                finish("连接失败：\(error.localizedDescription)\n确认 DiPlay 已换成带 TCP 通道的构建版本。")
            case .waiting(let error):
                finish("等待中（可能是本地网络权限）：\(error.localizedDescription)")
            default:
                return
            }
        }
        conn.start(queue: queue)
    }

    /// Sends INFO once to confirm framing, then ECHO payloads of increasing size.
    private func performEchoSeries(
        on conn: NWConnection,
        queue: DispatchQueue,
        token: UInt64,
        finish: @escaping (String) -> Void
    ) {
        var lines: [String] = []
        let seriesQueue = DispatchQueue(label: "ncmprobe.tcpseries")

        func sendInfoAndThenEcho() {
            let infoFrame = Self.buildFrame(op: 2, body: [])
            sendReceive(conn, frame: infoFrame, queue: seriesQueue) { result in
                switch result {
                case .failure(let msg):
                    finish("INFO 帧失败：\(msg)")
                case .success(let (status, body)):
                    guard token == self.runToken else { return }
                    if status != 0 {
                        finish("INFO 返回错误 status=\(status)")
                        return
                    }
                    let info = String(data: body, encoding: .utf8) ?? "<非 UTF-8>"
                    lines.append("握手成功 · \(info)")
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, token == self.runToken else { return }
                        self.log = lines.joined(separator: "\n") + "\n"
                    }
                    runEchoes()
                }
            }
        }

        func runEchoes() {
            let sizes = Self.payloadSizes
            func next(_ index: Int) {
                guard token == self.runToken else { return }
                if index >= sizes.count {
                    let summary = Self.summarize(lines)
                    conn.cancel()
                    finish(lines.joined(separator: "\n") + "\n\n" + summary)
                    return
                }
                let size = sizes[index]
                let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0) })
                let frame = Self.buildFrame(op: Self.opEcho, body: Array(payload))
                let start = Date()
                sendReceive(conn, frame: frame, queue: seriesQueue) { result in
                    guard token == self.runToken else { return }
                    switch result {
                    case .failure(let msg):
                        conn.cancel()
                        finish(lines.joined(separator: "\n") + "\n\n第 \(index + 1) 轮失败：\(msg)")
                    case .success(let (status, body)):
                        let elapsed = Date().timeIntervalSince(start)
                        if status != 0 {
                            conn.cancel()
                            finish(lines.joined(separator: "\n") + "\n\nECHO 返回错误 status=\(status)")
                            return
                        }
                        guard body.count == size else {
                            conn.cancel()
                            finish(lines.joined(separator: "\n") + "\n\n回显长度不符：期望 \(size)，实得 \(body.count)")
                            return
                        }
                        let mbps = Double(size) * 8.0 / elapsed / 1_000_000.0
                        lines.append(String(format: "%6d B  往返 %5.1f ms  →  %6.2f Mbps", size, elapsed * 1000, mbps))
                        DispatchQueue.main.async { [weak self] in
                            guard let self = self, token == self.runToken else { return }
                            self.log = lines.joined(separator: "\n") + "\n"
                        }
                        next(index + 1)
                    }
                }
            }
            next(0)
        }

        sendInfoAndThenEcho()
    }

    /// Sends one framed request and reads exactly one framed response.
    private func sendReceive(
        _ conn: NWConnection,
        frame: Data,
        queue: DispatchQueue,
        completion: @escaping (Result<(Int, Data), ProbeError>) -> Void
    ) {
        conn.send(content: frame, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { err in
            if let err = err {
                completion(.failure(ProbeError("发送失败：\(err.localizedDescription)")))
                return
            }
            Self.readExactly(conn, count: 9, queue: queue) { header in
                guard let header = header else {
                    completion(.failure(ProbeError("读取响应头超时或连接关闭")))
                    return
                }
                let bytes = [UInt8](header)
                guard Array(bytes[0..<4]) == Self.magicResponse else {
                    completion(.failure(ProbeError("响应 magic 不符")))
                    return
                }
                let status = Int(bytes[4])
                // DiPlay writes the length with Java DataOutputStream.writeInt (big-endian).
                let length = (Int(bytes[5]) << 24) | (Int(bytes[6]) << 16) | (Int(bytes[7]) << 8) | Int(bytes[8])
                guard length >= 0, length <= 4 * 1024 * 1024 else {
                    completion(.failure(ProbeError("响应长度异常：\(length)")))
                    return
                }
                if length == 0 {
                    completion(.success((status, Data())))
                    return
                }
                Self.readExactly(conn, count: length, queue: queue) { body in
                    guard let body = body else {
                        completion(.failure(ProbeError("读取响应体超时或连接关闭")))
                        return
                    }
                    completion(.success((status, body)))
                }
            }
        })
    }

    /// Reads exactly `count` bytes, tolerating partial TCP reads.
    private static func readExactly(
        _ conn: NWConnection,
        count: Int,
        queue: DispatchQueue,
        completion: @escaping (Data?) -> Void
    ) {
        var buffer = Data()
        func pump() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: count - buffer.count) { data, _, isComplete, error in
                if let data = data { buffer.append(data) }
                if buffer.count >= count {
                    completion(buffer.prefix(count))
                    return
                }
                if isComplete || error != nil {
                    completion(nil)
                    return
                }
                pump()
            }
        }
        pump()
    }

    private static func buildFrame(op: UInt8, body: [UInt8]) -> Data {
        var frame = Data()
        frame.append(contentsOf: magicRequest)
        frame.append(op)
        let n = UInt32(body.count)
        // Big-endian, matching Java DataInputStream.readInt on the DiPlay side.
        frame.append(UInt8(truncatingIfNeeded: n >> 24))
        frame.append(UInt8(truncatingIfNeeded: n >> 16))
        frame.append(UInt8(truncatingIfNeeded: n >> 8))
        frame.append(UInt8(truncatingIfNeeded: n))
        frame.append(contentsOf: body)
        return frame
    }

    private static func summarize(_ lines: [String]) -> String {
        let mbpsLines = lines.filter { $0.contains("Mbps") }
        guard !mbpsLines.isEmpty else { return "没有有效的吞吐量样本。" }
        let values = mbpsLines.compactMap { line -> Double? in
            guard let idx = line.range(of: "  →  ") else { return nil }
            let tail = line[idx.upperBound...]
            return Double(tail.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " Mbps", with: ""))
        }
        guard let best = values.max() else { return "无法解析吞吐量。" }
        return String(format: "最高吞吐 %.2f Mbps（大包更接近链路真实带宽上限）。", best)
    }

    func cancel() {
        runToken += 1
        connection?.cancel()
        connection = nil
        isRunning = false
    }
}
