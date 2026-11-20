import LanternfishKit
import SwiftUI

/// Service Details sheet: deep inspection of one open port (connection, HTTP headers,
/// TLS certificate chain, SSH host keys, raw banner).
struct ServiceDetailsView: View {
    let target: ServiceDetailsTarget
    @Environment(\.dismiss) private var dismiss

    @State private var report: ServiceReport?
    @State private var isLoading = true
    @State private var generation = 0
    @State private var refreshOwner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 640, height: 520)
        .task(id: generation) { await load() }
        // ⌘R (File menu) inspects again while this sheet is up.
        .onChange(of: isLoading, initial: true) { publishRefresh() }
        .onDisappear { Router.shared.setRefresh(nil, owner: refreshOwner) }
    }

    private func publishRefresh() {
        let generation = $generation
        Router.shared.setRefresh(
            SceneRefresh(title: "Inspect Again", isDisabled: isLoading) {
                generation.wrappedValue += 1
            }, owner: refreshOwner)
    }

    // MARK: Loading

    private func load() async {
        isLoading = true
        let result = await ServiceProbe.inspect(target.ip, port: target.port.port)
        guard !Task.isCancelled else { return }
        withAnimation(.snappy) {
            report = result
            isLoading = false
        }
    }

    // MARK: Header

    private var serviceName: String {
        if let s = target.port.service, !s.isEmpty { return s }
        if let p = report?.detectedProtocol, p != .unknown { return p.label }
        return "Port \(target.port.port)"
    }

    private var address: String { "\(target.ip):\(target.port.port)" }

    /// Where "Open in Browser" goes: the scheme that actually answered, else the port's default.
    private var browserURL: URL? {
        let p = target.port.port
        func url(_ scheme: String) -> URL? {
            let isDefault = (scheme == "https" && p == 443) || (scheme == "http" && p == 80)
            return URL(string: "\(scheme)://\(target.ip)\(isDefault ? "" : ":\(p)")/")
        }
        switch report?.detectedProtocol {
        case .https?: return url("https")
        case .http?: return url("http")
        case nil: return target.port.url(host: target.ip)
        default: return nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            PortBadge(port: target.port.port, tint: report?.detectedProtocol.tint ?? .gray)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(serviceName)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    if let p = report?.detectedProtocol, p != .unknown,
                        p.label.caseInsensitiveCompare(serviceName) != .orderedSame
                    {
                        DetailBadge(text: p.label, tint: p.tint)
                    }
                }
                Text(address)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            if isLoading, report != nil {
                ProgressView().controlSize(.small)
            }
            if let url = browserURL {
                Button("Open in Browser", systemImage: "safari") { DeviceActions.open(url) }
                    .help(url.absoluteString)
            }
            CopyButton("Copy All", help: "Copy the whole report as text", bordered: true) { report?.plainText }
                .disabled(report == nil)
            Button("Inspect Again", systemImage: "arrow.clockwise") { generation += 1 }
                .labelStyle(.iconOnly)
                .help("Inspect again (⌘R)")
                .disabled(isLoading)
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let report {
            ServiceReportForm(report: report)
                .opacity(isLoading ? 0.6 : 1)
        } else {
            VStack(spacing: 10) {
                ProgressView()
                Text("Inspecting \(address)…")
                    .foregroundStyle(.secondary)
                Text("Reading the banner, then trying HTTP, TLS or SSH")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Report

/// The report's sections in a grouped form.
private struct ServiceReportForm: View {
    let report: ServiceReport

    var body: some View {
        Form {
            connection
            if let http = report.http { HTTPSection(http: http) }
            if let tls = report.tls {
                TLSSection(tls: tls)
            } else if let e = report.tlsError {
                Section("TLS") { InlineError(message: e) }
            }
            if let ssh = report.ssh { SSHSection(ssh: ssh, error: report.sshError) }
            if report.banner != nil { BannerSection(report: report) }
        }
        .formStyle(.grouped)
    }

    private var connection: some View {
        Section("Connection") {
            if let e = report.connectError {
                InlineError(message: "Couldn't connect: \(e)")
            }
            if let t = report.connectTime {
                LabeledContent("Connect time", value: ServiceProbe.format(t))
            }
            if let t = report.tls?.handshakeTime {
                LabeledContent("TCP + TLS handshake", value: ServiceProbe.format(t))
            }
            LabeledContent("Protocol") {
                HStack(spacing: 6) {
                    if report.detectedProtocol != .unknown {
                        Circle().fill(report.detectedProtocol.tint).frame(width: 7, height: 7)
                    }
                    Text(protocolDescription)
                }
            }
            if report.connectError == nil, report.banner == nil, report.http == nil, report.tls == nil,
                report.ssh == nil
            {
                Text("The service accepted the connection but sent nothing, and didn't answer HTTP or TLS.")
                    .foregroundStyle(.secondary)
            }
            if let e = report.httpError, report.tls == nil, report.ssh == nil, report.banner == nil {
                InlineError(message: e, isWarning: true)
            }
        }
    }

    private var protocolDescription: String {
        switch report.detectedProtocol {
        case .unknown: report.connectError == nil ? (report.banner == nil ? "Silent" : "Unrecognized") : "—"
        case .https where report.tls == nil: "HTTPS (handshake failed)"
        case let p: p.label
        }
    }
}

// MARK: - HTTP

private struct HTTPSection: View {
    let http: HTTPInfo

    var body: some View {
        Section {
            if let final = http.final {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(statusTint(final.statusCode)).frame(width: 7, height: 7)
                        Text(final.statusLine).monospaced().textSelection(.enabled)
                    }
                }
                if http.redirected || http.unfollowedRedirect != nil {
                    LabeledContent("Redirects") {
                        VStack(alignment: .trailing, spacing: 2) {
                            ForEach(Array(http.responses.dropLast().enumerated()), id: \.offset) { _, r in
                                Text(verbatim: "\(r.statusCode) \(r.url.absoluteString)")
                            }
                            if let next = http.unfollowedRedirect {
                                Text("→ \(next) (not followed)").foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                    }
                }
                LabeledContent("Final URL") {
                    Text(final.url.absoluteString).monospaced().textSelection(.enabled)
                }
                if let title = final.title {
                    LabeledContent("Page title") { Text(title).textSelection(.enabled) }
                }
                if let type = final.contentType {
                    LabeledContent("Content type", value: type)
                }
                LabeledContent(
                    "Body size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(final.bodySize), countStyle: .file)
                        + (final.bodyTruncated ? "+" : ""))
                DisclosureGroup("Response headers (\(final.headers.count))") {
                    HeaderGrid(headers: final.headers)
                }
                ForEach(Array(http.responses.dropLast().enumerated()), id: \.offset) { _, r in
                    DisclosureGroup("Headers of \(r.statusCode) from \(r.url.path.isEmpty ? "/" : r.url.path)") {
                        HeaderGrid(headers: r.headers)
                    }
                }
            }
        } header: {
            HStack {
                Text("HTTP")
                Spacer()
                if let final = http.final {
                    CopyButton(
                        text: ([final.statusLine] + final.headers.map { "\($0.name): \($0.value)" })
                            .joined(separator: "\n"), help: "Copy status line and headers")
                }
            }
        }
    }

    private func statusTint(_ code: Int) -> Color {
        switch code {
        case 200..<300: .green
        case 300..<400: .blue
        case 400..<500: .orange
        default: .red
        }
    }
}

/// Monospaced, selectable name/value grid.
private struct HeaderGrid: View {
    let headers: [HTTPHeader]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(Array(headers.enumerated()), id: \.offset) { _, h in
                GridRow {
                    Text(h.name)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(h.value)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}

// MARK: - TLS

private struct TLSSection: View {
    let tls: TLSInfo

    var body: some View {
        Section("TLS Certificate") {
            if let v = tls.protocolVersion {
                LabeledContent("Protocol", value: v)
            }
            if let c = tls.cipherSuite {
                LabeledContent("Cipher suite") { Text(c).monospaced().textSelection(.enabled) }
            }
            LabeledContent("System trust") {
                if tls.trusted {
                    Label("Trusted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Not trusted", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(tls.trustError ?? "")
                }
            }
            if !tls.trusted, let e = tls.trustError {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if tls.certificates.isEmpty {
                Text("The server sent no certificates.").foregroundStyle(.secondary)
            }
            ForEach(Array(tls.certificates.enumerated()), id: \.offset) { i, cert in
                CertificateRow(cert: cert, index: i, count: tls.certificates.count)
            }
        }
    }
}

private struct CertificateRow: View {
    let cert: CertificateInfo
    let index: Int
    let count: Int
    @State private var expanded: Bool

    init(cert: CertificateInfo, index: Int, count: Int) {
        self.cert = cert
        self.index = index
        self.count = count
        _expanded = State(initialValue: index == 0)
    }

    private var role: String {
        if index == 0 { return count > 1 ? "Leaf" : "Certificate" }
        return index == count - 1 && cert.isSelfSigned ? "Root" : "Intermediate"
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                field("Subject", cert.subject.description)
                field("Issuer", cert.issuer.description)
                if !cert.subjectAltNames.isEmpty {
                    field("Alt names", cert.subjectAltNames.joined(separator: "\n"))
                }
                if let d = cert.notBefore {
                    field("Valid from", ServiceProbe.formatDate(d), tint: cert.isNotYetValid ? .red : nil)
                }
                if let d = cert.notAfter {
                    field("Valid until", ServiceProbe.formatDate(d) + expiryNote, tint: cert.expiryTint)
                }
                if let k = cert.keyDescription { field("Public key", k) }
                if let s = cert.signatureAlgorithm { field("Signature", s) }
                if let s = cert.serialNumber { field("Serial", s, mono: true) }
                if let v = cert.version { field("Version", "\(v)" + (cert.isCA ? " (CA)" : "")) }
                GridRow {
                    label("SHA-256")
                    HStack(alignment: .top, spacing: 4) {
                        Text(cert.sha256Fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        CopyButton(text: cert.sha256Fingerprint, help: "Copy SHA-256 fingerprint")
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: index == 0 ? "checkmark.seal" : "seal")
                    .foregroundStyle(cert.expiryTint ?? .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cert.displayName).fontWeight(.medium).lineLimit(1)
                    Text("\(role) · issued by \(cert.issuerCN ?? cert.issuerO ?? "unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if cert.isSelfSigned { DetailBadge(text: "Self-signed", tint: .purple) }
                if cert.isExpired {
                    DetailBadge(text: "Expired", tint: .red)
                } else if cert.isNotYetValid {
                    DetailBadge(text: "Not yet valid", tint: .red)
                } else if cert.expiresSoon, let d = cert.daysUntilExpiry {
                    DetailBadge(text: d == 0 ? "Expires today" : "Expires in \(d)d", tint: .orange)
                }
            }
        }
    }

    private var expiryNote: String {
        guard let d = cert.daysUntilExpiry else { return "" }
        if cert.isExpired { return "  (expired \(-d) day\(-d == 1 ? "" : "s") ago)" }
        return "  (\(d) day\(d == 1 ? "" : "s") left)"
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.caption)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func field(_ name: String, _ value: String, tint: Color? = nil, mono: Bool = false) -> some View {
        GridRow {
            label(name)
            Text(value)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(tint ?? .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

// MARK: - SSH

private struct SSHSection: View {
    let ssh: SSHInfo
    let error: String?

    var body: some View {
        Section("SSH") {
            LabeledContent("Version") {
                Text(ssh.versionLine).monospaced().textSelection(.enabled)
            }
            if let p = ssh.protocolVersion {
                LabeledContent("Protocol", value: p == "2.0" ? "SSH 2" : p)
            }
            if let e = error { InlineError(message: e, isWarning: true) }
            ForEach(ssh.hostKeys, id: \.self) { key in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: "key.horizontal")
                            .foregroundStyle(.secondary)
                        Text(key.typeLabel).fontWeight(.medium)
                        if let bits = key.bits {
                            Text(verbatim: "\(bits)-bit").foregroundStyle(.secondary)
                        }
                        Text(key.algorithm)
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        Spacer()
                        CopyButton(text: key.fingerprint, help: "Copy fingerprint")
                        CopyButton(
                            text: "\(key.algorithm) \(key.publicKey)", symbol: "key",
                            help: "Copy public key (known_hosts format)")
                    }
                    Text(key.fingerprint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

// MARK: - Banner

private struct BannerSection: View {
    let report: ServiceReport
    @State private var mode: Mode = .text

    enum Mode: String, CaseIterable, Identifiable {
        case text = "Text"
        case hex = "Hex"
        var id: Self { self }
    }

    var body: some View {
        Section {
            ScrollView([.vertical, .horizontal]) {
                Text(shown)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            .frame(minHeight: 60, maxHeight: 180)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        } header: {
            HStack {
                Text("Raw Banner")
                if let n = report.banner?.count {
                    Text(verbatim: "\(n) bytes\(report.bannerTruncated ? "+" : "")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("Format", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                CopyButton(text: shown, help: "Copy banner")
            }
        }
    }

    private var shown: String {
        (mode == .text ? report.bannerText : report.bannerHex) ?? ""
    }
}
