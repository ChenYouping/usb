import Foundation
import Darwin

struct InterfaceEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let family: String
    let address: String
    let flags: String
    let scopeID: UInt32
    let isLinkLocal: Bool
}

enum InterfaceProbe {
    // Interfaces iOS normally has on its own. Anything link-local outside
    // this set is a candidate for the USB NCM / CarPlay link.
    static let commonNames: Set<String> = [
        "lo0", "en0", "en1", "en2", "awdl0", "llw0",
        "pdp_ip0", "pdp_ip1", "bridge100",
        "utun0", "utun1", "utun2", "utun3", "utun4"
    ]

    static func scan() -> [InterfaceEntry] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceEntry] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let p = cursor {
            let info = p.pointee
            if let sa = info.ifa_addr {
                let family = Int32(sa.pointee.sa_family)

                if family == AF_INET || family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let length = socklen_t(sa.pointee.sa_len)

                    if getnameinfo(sa, length, &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let name = String(cString: info.ifa_name)
                        let address = String(cString: host)
                        let f = Int32(info.ifa_flags)
                        var parts: [String] = []
                        if (f & IFF_UP) != 0 { parts.append("UP") }
                        if (f & IFF_RUNNING) != 0 { parts.append("RUNNING") }
                        if (f & IFF_LOOPBACK) != 0 { parts.append("LOOPBACK") }
                        if (f & IFF_POINTOPOINT) != 0 { parts.append("P2P") }

                        let familyName = family == AF_INET6 ? "IPv6" : "IPv4"
                        let scope: UInt32 = family == AF_INET6
                            ? if_nametoindex(info.ifa_name) : 0
                        let linkLocal = family == AF_INET6
                            && address.lowercased().hasPrefix("fe80")

                        result.append(InterfaceEntry(
                            id: "\(name)-\(familyName)-\(address)",
                            name: name,
                            family: familyName,
                            address: address,
                            flags: parts.joined(separator: ","),
                            scopeID: scope,
                            isLinkLocal: linkLocal
                        ))
                    }
                }
            }
            cursor = info.ifa_next
        }

        return result.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }

    static func isCandidate(_ entry: InterfaceEntry) -> Bool {
        entry.family == "IPv6"
            && entry.isLinkLocal
            && !commonNames.contains(entry.name)
    }

    static func report(_ entries: [InterfaceEntry]) -> String {
        var lines = ["NcmProbe interface dump", "generated: \(Date())", ""]
        for e in entries {
            lines.append("\(e.name)\t\(e.family)\t\(e.address)\tscope=\(e.scopeID)\t\(e.flags)\(e.isLinkLocal ? "\tLINK-LOCAL" : "")")
        }
        let candidates = entries.filter(isCandidate)
        lines.append("")
        lines.append("candidates: \(candidates.count)")
        for e in candidates {
            lines.append("  -> \(e.name) \(e.address)%\(e.name) (scope \(e.scopeID))")
        }
        return lines.joined(separator: "\n")
    }
}
