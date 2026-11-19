import Foundation
import Darwin
import Network

/// Probes the DiPlay listener across the USB NCM link.
///
/// Wired DiPlay uses a fixed car-side tunnel address (fe80::2) and binds its
/// AirPlay control listener to the first free port in 7000...7010. A successful
/// TCP handshake from a third-party app proves the app can reach DiPlay over
/// the NCM IPv6 link — the question this probe set was built to answer.
///
/// Note: a ready socket only proves reachability. The listener speaks AirPlay
/// (RTSP), so arbitrary bytes will be answered with a protocol error or closed.
///
/// IMPORTANT (crash fix): NWConnection's stateUpdateHandler fires MULTIPLE times
/// per connection (e.g. .waiting then .ready). An earlier version called
/// DispatchGroup.leave() on every fire, so leave() outnumbered enter() and the
/// app crashed. Here every probe settles EXACTLY once, guarded by ScanContext.
final class ConnectionTester: ObservableObject {
    @Published var log: String = "尚未测试"
    @Published var isScanning: Bool = false

    private var connections: [NWConnection] = []
    private var scanToken: UInt64 = 0

    private static let diPlayAddress = "fe80::2"
    private static let diPlayPorts: [UInt16] = Array(7000...7010)
    private static let timeoutSeconds: Double = 3.0

    // MARK: - Single target test

    func test(host: String, port: UInt16) {
        cancelAll()
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            log = "地址或端口无效"
            return
        }
        let ctx = ScanContext(token: scanToken, total: 1)
        log = "连接中 \(trimmed):\(port) …"
        startProbe(host: trimmed, port: nwPort, context: ctx) { [weak self] p, line, _ in
            guard let self = self else { return }
            guard ctx.settle(port: p, line: line, isReady: false) != nil else { return }
            DispatchQueue.main.async { self.log = line }
        }
    }

    // MARK: - DiPlay port scan

    func scanDiPlay(interface: String) {
        cancelAll()
        let iface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedHost = iface.isEmpty ? Self.diPlayAddress : "\(Self.diPlayAddress)%\(iface)"

        guard iface.isEmpty || if_nametoindex(iface) != 0 else {
            log = "找不到接口 \(iface)，先在「判定结果」里确认 NCM 接口名"
            return
        }

        scanToken += 1
        let ctx = ScanContext(token: scanToken, total: Self.diPlayPorts.count)
        isScanning = true
        log = "在 \(iface) 上扫描 \(scopedHost) 的端口 7000–7010 …\n"

        for port in Self.diPlayPorts {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            startProbe(host: scopedHost, port: nwPort, context: ctx) { [weak self] p, line, isReady in
                guard let self = self else { return }
                guard let snap = ctx.settle(port: p, line: line, isReady: isReady) else { return }
                DispatchQueue.main.async {
                    guard ctx.token == self.scanToken else { return }
                    self.log = snap.text
                    if snap.done {
                        self.isScanning = false
                        if snap.ready.isEmpty {
                            self.log += "\n\n没有端口握手成功。确认 CarPlay 画面已出、接口名正确、本地网络权限已允许。"
                        } else {
                            self.log += "\n\n链路已通：DiPlay 在端口 \(snap.ready.map(String.init).joined(separator: ", ")) 应答。"
                            self.log += "\n注意：这是 AirPlay 控制端口，只讲 RTSP，不要直接把任意字节当数据发。"
                        }
                    }
                }
            }
        }
    }

    // MARK: - Core probe: each connection settles exactly once

    private func startProbe(
        host: String,
        port: NWEndpoint.Port,
        context: ScanContext,
        onSettle: @escaping (UInt16, String, Bool) -> Void
    ) {
        let p = port.rawValue
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connections.append(conn)

        // Timeout fallback: a stuck .waiting (e.g. localNetworkDenied) must still settle.
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeoutSeconds) {
            onSettle(p, "timeout \(host):\(p)", false)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                onSettle(p, "ready  \(host):\(p)", true)
            case .failed(let error):
                onSettle(p, "failed  \(host):\(p) — \(error.localizedDescription)", false)
            default:
                // .setup / .waiting / .cancelled do not settle; wait for a
                // terminal state or the timeout above.
                return
            }
        }
        conn.start(queue: DispatchQueue(label: "ncmprobe.connection", attributes: .concurrent))
    }

    private func cancelAll() {
        scanToken += 1
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isScanning = false
    }
}

// MARK: - Thread-safe, one settlement per port

private final class ScanContext {
    let token: UInt64
    private let lock = NSLock()
    private var finished = Set<UInt16>()
    private var lines: [String] = []
    private var readyPorts: [UInt16] = []

    init(token: UInt64, total: Int) {
        self.token = token
        self.total = total
    }

    private let total: Int

    /// Only the first call for a given port is accepted; duplicates return nil.
    /// This is what prevents the DispatchGroup over-leave crash.
    func settle(port: UInt16, line: String, isReady: Bool) -> (text: String, done: Bool, ready: [UInt16])? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished.contains(port) else { return nil }
        finished.insert(port)
        lines.append(line)
        if isReady { readyPorts.append(port) }
        return (lines.joined(separator: "\n"), finished.count == total, readyPorts)
    }
}
