import Foundation
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
final class ConnectionTester: ObservableObject {
    @Published var log: String = "尚未测试"
    @Published var isScanning: Bool = false
    private var connections: [NWConnection] = []

    private static let diPlayAddress = "fe80::2"
    private static let diPlayPorts: [UInt16] = Array(7000...7010)

    /// Single-target test. For a link-local IPv6 address include the scope
    /// suffix, e.g. "fe80::2%en2"; Network.framework resolves the zone itself.
    func test(host: String, port: UInt16) {
        cancelAll()
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            log = "地址或端口无效"
            return
        }
        log = "连接中 \(trimmed):\(port) …"
        connect(host: trimmed, port: nwPort) { [weak self] result in
            self?.log = result
        }
    }

    /// Scans DiPlay's fixed address over the NCM interface. Pass the NCM
    /// interface name (e.g. "en2") — it is appended as "%en2" to the address.
    func scanDiPlay(interface: String) {
        cancelAll()
        let iface = interface.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedHost = iface.isEmpty ? Self.diPlayAddress : "\(Self.diPlayAddress)%\(iface)"

        guard iface.isEmpty || if_nametoindex(iface) != 0 else {
            isScanning = false
            log = "找不到接口 \(iface)，先在「判定结果」里确认 NCM 接口名"
            return
        }

        isScanning = true
        log = "在 \(iface) 上扫描 \(scopedHost) 的端口 7000–7010 …\n"
        let group = DispatchGroup()
        let resultLock = NSLock()
        var lines: [String] = []
        var readyPorts: [UInt16] = []

        for port in Self.diPlayPorts {
            guard let nwPort = NWEndpoint.Port(rawValue: port) else { continue }
            group.enter()
            connect(host: scopedHost, port: nwPort) { result in
                resultLock.lock()
                lines.append(result)
                if result.hasPrefix("ready") { readyPorts.append(port) }
                let snapshot = lines
                resultLock.unlock()
                DispatchQueue.main.async { self.log = snapshot.joined(separator: "\n") }
                group.leave()
            }
        }

        group.notify(queue: DispatchQueue.main) { [weak self] in
            guard let self = self else { return }
            self.isScanning = false
            if readyPorts.isEmpty {
                self.log += "\n\n没有端口握手成功。确认 CarPlay 画面已出、接口名正确、本地网络权限已允许。"
            } else {
                self.log += "\n\n链路已通：DiPlay 在端口 \(readyPorts.map(String.init).joined(separator: ", ")) 应答。"
                self.log += "\n注意：这是 AirPlay 控制端口，只讲 RTSP，不要直接把任意字节当数据发。"
            }
        }
    }

    private func connect(
        host: String,
        port: NWEndpoint.Port,
        completion: @escaping (String) -> Void
    ) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        connections.append(conn)
        conn.stateUpdateHandler = { state in
            let line: String
            switch state {
            case .ready:
                line = "ready  \(host):\(port)"
            case .waiting(let error):
                line = "waiting \(host):\(port) — \(String(describing: error))"
            case .failed(let error):
                line = "failed  \(host):\(port) — \(error.localizedDescription)"
            default:
                return
            }
            completion(line)
        }
        conn.start(queue: DispatchQueue(label: "ncmprobe.connection", attributes: .concurrent))
    }

    private func cancelAll() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isScanning = false
    }
}
