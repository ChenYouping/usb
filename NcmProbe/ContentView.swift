import SwiftUI
import UIKit

struct ContentView: View {
    @State private var entries: [InterfaceEntry] = InterfaceProbe.scan()
    @State private var host: String = ""
    @State private var port: String = "7100"
    @State private var showCopied = false
    @StateObject private var tester = ConnectionTester()

    private var candidates: [InterfaceEntry] {
        entries.filter(InterfaceProbe.isCandidate)
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("判定结果")) {
                    if candidates.isEmpty {
                        Text("未发现可疑的 USB NCM 接口")
                            .foregroundColor(.secondary)
                        Text("先确认 DiPlay 有线 CarPlay 已经出画面，再点右上角重新扫描。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(candidates) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.name)
                                    .font(.headline)
                                Text("\(entry.address)  scope=\(entry.scopeID)")
                                    .font(.system(.caption, design: .monospaced))
                                Text("疑似 NCM / CarPlay 链路")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section(header: Text("全部接口 (\(entries.count))")) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.name).font(.body)
                                Spacer()
                                Text(entry.family)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text(entry.address)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                            Text("scope=\(entry.scopeID)  \(entry.flags)\(entry.isLinkLocal ? "  LINK-LOCAL" : "")")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section(header: Text("DiPlay 链路探测")) {
                    if let candidate = candidates.first {
                        Text("NCM 接口：\(candidate.name)  scope=\(candidate.scopeID)")
                            .font(.system(.caption, design: .monospaced))
                        Button(action: {
                            tester.scanDiPlay(interface: candidate.name)
                        }) {
                            HStack {
                                Text("扫描 DiPlay（fe80::2 · 端口 7000–7010）")
                                if tester.isScanning { ProgressView() }
                            }
                        }
                        .disabled(tester.isScanning)
                    } else {
                        Text("没找到 NCM 接口，先跑 CarPlay 再重新扫描")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text(tester.log)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Section(header: Text("手动连通性测试")) {
                    TextField("IPv6 地址或主机名（link-local 请带 %接口名）", text: $host)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(.caption, design: .monospaced))
                    HStack {
                        TextField("端口", text: $port)
                            .keyboardType(.numberPad)
                            .frame(maxWidth: 100)
                        Button("连接") {
                            tester.test(host: host, port: UInt16(port) ?? 7100)
                        }
                    }
                }

                Section(header: Text("操作")) {
                    Button("复制完整报告") {
                        UIPasteboard.general.string = InterfaceProbe.report(entries)
                        showCopied = true
                    }
                    Text("把复制的内容发回来，就能确定哪条接口是 NCM、有没有 fe80:: 地址。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("NCM 接口探测")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重新扫描") { entries = InterfaceProbe.scan() }
                }
            }
            .alert("已复制报告", isPresented: $showCopied) {
                Button("好", action: {})
            }
        }
    }
}
