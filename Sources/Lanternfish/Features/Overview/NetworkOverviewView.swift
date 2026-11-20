import LanternfishKit
import SwiftUI

/// The Network Overview popover: health, internet, local network, Wi-Fi and a speed test.
struct NetworkOverviewView: View {
    let store: ScanStore
    @State private var model = OverviewModel.shared
    @State private var refreshOwner = UUID()

    private var interface: NetworkInterfaceInfo? { store.selectedInterface }

    private var gatewayDevice: Device? {
        guard let gw = interface?.gateway else { return nil }
        return store.devices.first { $0.ip == gw }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    OverviewHealthSection(store: store)
                    OverviewInternetSection(model: model)
                    OverviewLocalSection(model: model, interface: interface, gatewayDevice: gatewayDevice)
                    if let wifi = model.wifi, model.link?.medium == .wifi {
                        OverviewWiFiSection(model: model, wifi: wifi)
                    }
                    OverviewSpeedTestSection(model: model)
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(width: 380)
        .frame(minHeight: 300, idealHeight: 620, maxHeight: 680)
        .task(id: interface?.id) {
            model.load(interface: interface)
            // Keep Wi-Fi signal figures fresh while the popover is open.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                model.refreshWiFi(interface: interface)
            }
        }
        .onChange(of: model.location.changeCount) {
            model.refreshWiFi(interface: interface)
        }
        // ⌘R (File menu) refreshes the overview while the popover is up.
        .onChange(of: model.isLoadingInternet, initial: true) { publishRefresh() }
        // ⌘K "Run Speed Test" opened (or found open) the popover.
        .onChange(of: Router.shared.pendingSpeedTest, initial: true) { startPendingSpeedTest() }
        .onDisappear {
            Router.shared.setRefresh(nil, owner: refreshOwner)
            // A speed test belongs to the open popover: closing it stops the test.
            model.cancelSpeedTest()
        }
    }

    private func startPendingSpeedTest() {
        guard Router.shared.pendingSpeedTest else { return }
        Router.shared.pendingSpeedTest = false
        model.startSpeedTest()
    }

    private func publishRefresh() {
        Router.shared.setRefresh(
            SceneRefresh(title: "Refresh Overview", isDisabled: model.isLoadingInternet) {
                [model, interface] in model.load(interface: interface, force: true)
            }, owner: refreshOwner)
    }

    private var header: some View {
        HStack {
            Text("Network Overview")
                .font(.title3.weight(.semibold))
            Spacer()
            if model.isLoadingInternet {
                ProgressView().controlSize(.small)
            }
            Button {
                model.load(interface: interface, force: true)
            } label: {
                Label("Refresh Overview", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Refresh (⌘R)")
            .disabled(model.isLoadingInternet)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
