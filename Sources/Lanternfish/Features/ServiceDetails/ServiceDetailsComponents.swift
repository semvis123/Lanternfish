import LanternfishKit
import SwiftUI

// Small building blocks for the Service Details sheet.

extension ServiceProtocol {
    var tint: Color {
        switch self {
        case .https: .green
        case .http: .blue
        case .tls: .teal
        case .ssh: .indigo
        case .ftp, .telnet: .brown
        case .smtp, .pop3, .imap: .orange
        case .vnc, .rtsp: .purple
        case .mysql, .redis: .pink
        case .unknown: .gray
        }
    }
}

extension CertificateInfo {
    /// Red when expired / not yet valid, orange inside 30 days, nil otherwise.
    var expiryTint: Color? {
        if isExpired || isNotYetValid { return .red }
        if expiresSoon { return .orange }
        return nil
    }
}

/// The port number on a tinted rounded square, in the style of `DeviceIconView`.
struct PortBadge: View {
    let port: UInt16
    let tint: Color
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tint.gradient)
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(.black.opacity(0.08), lineWidth: 0.5)
            }
            .overlay {
                Text(String(port))
                    .font(.system(size: size * 0.36, weight: .bold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, 3)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("Port \(port)")
    }
}

/// A small tinted capsule ("Self-signed", "Expired", "HTTPS").
struct DetailBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
            .fixedSize()
    }
}

/// An error or warning shown inline in a section.
struct InlineError: View {
    let message: String
    var isWarning = false

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: isWarning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                .foregroundStyle(isWarning ? .orange : .red)
        }
        .font(.callout)
    }
}
