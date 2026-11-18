import Foundation
import Network

final class ConnectionTester: ObservableObject {
    @Published var log: String = "尚未测试"
    private var connection: NWConnection?

    func test(host: String, port: UInt16) {
        connection?.cancel()

        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else {
            log = "地址或端口无效"
            return
        }

        let endpoint: NWEndpoint.Host
        if let v6 = IPv6Address(trimmed) {
            endpoint = .ipv6(v6)
        } else if let v4 = IPv4Address(trimmed) {
            endpoint = .ipv4(v4)
        } else {
            endpoint = .name(trimmed, nil)
        }

        let conn = NWConnection(host: endpoint, port: nwPort, using: .tcp)
        connection = conn
        log = "连接中 \(trimmed):\(port) ..."

        conn.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.log = "ready — 链路通了"
                    self?.connection?.cancel()
                case .waiting(let error):
                    self?.log = "waiting — \(error.localizedDescription) [\(String(describing: error))]"
                case .failed(let error):
                    self?.log = "failed — \(error.localizedDescription)"
                case .cancelled:
                    break
                default:
                    self?.log = String(describing: state)
                }
            }
        }

        conn.start(queue: DispatchQueue(label: "ncmprobe.connection"))
    }
}
