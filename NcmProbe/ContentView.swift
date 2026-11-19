import SwiftUI
import UIKit
import CoreImage

struct ContentView: View {
    @State private var entries: [InterfaceEntry] = InterfaceProbe.scan()
    @State private var host: String = ""
    @State private var port: String = "7100"
    @State private var showCopied = false
    @StateObject private var tester = ConnectionTester()
    @StateObject private var tcpTester = TcpChannelTester()
    @StateObject private var video = VideoPreviewTester()

    private func uiImage(from pixel: CVPixelBuffer?) -> UIImage? {
        guard let pixel else { return nil }
        let ci = CIImage(cvPixelBuffer: pixel)
        let context = CIContext()
        guard let cg = context.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

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
                        Button(action: {
                            tester.rtspOptions(interface: candidate.name)
                        }) {
                            HStack {
                                Text("RTSP 握手（发 OPTIONS，验协议对话）")
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

                Section(header: Text("TCP 通道测速（需带通道的 DiPlay）")) {
                    if let candidate = candidates.first {
                        Text("目标 fe80::2:\(7100) · 接口 \(candidate.name)")
                            .font(.system(.caption, design: .monospaced))
                        Button(action: {
                            tcpTester.run(interface: candidate.name)
                        }) {
                            HStack {
                                Text("测速（1KB / 16KB / 64KB / 256KB 回环）")
                                if tcpTester.isRunning { ProgressView() }
                            }
                        }
                        .disabled(tcpTester.isRunning)
                        HStack {
                            Text(tcpTester.log)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                            Spacer()
                            if tcpTester.isRunning {
                                Button("停止") { tcpTester.cancel() }
                            }
                        }
                        Text("只有把 DiPlay 换成带 TCP 通道的构建版本后才有 7100 端口；官方 APK 没有这个端口。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("没找到 NCM 接口，先跑 CarPlay 再重新扫描")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section(header: Text("视频预览（需带视频通道的 DiPlay · 端口 7101）")) {
                    if let candidate = candidates.first {
                        if let image = uiImage(from: video.latestImage) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 320)
                                .cornerRadius(8)
                                .background(Color.black)
                        } else {
                            Text("小窗口待机：连接后显示 CarPlay 画面")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 120)
                        }
                        HStack {
                            if video.isConnected {
                                Button("断开视频") { video.disconnect() }
                            } else {
                                Button("连接视频（fe80::2 · 7101）") {
                                    video.connect(interface: candidate.name)
                                }
                            }
                            Spacer()
                            Text("帧 \(video.decodedFrames)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Text("状态：\(video.status)")
                            .font(.system(.caption2, design: .monospaced))
                        Text("步骤：\(video.step)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                        if !video.detail.isEmpty {
                            Text(video.detail)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        if !video.lastError.isEmpty {
                            Text(video.lastError)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.red)
                        }
                        Text("需要把 DiPlay 换成带视频通道的构建版本（端口 7101）；官方 APK 无此端口。点连接后才开始推流，断开即停。")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("没找到 NCM 接口，先跑 CarPlay 再重新扫描")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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
