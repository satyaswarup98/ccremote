import SwiftUI

@main
struct CCRemoteApp: App {
    @State private var client = BridgeClient()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(client)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear {
                    Notifier.shared.setup(client: client)
                    client.connect()
                }
                .onOpenURL { url in
                    // ccremote://session/<id>  (from ntfy notification taps)
                    if url.host() == "session", let id = url.pathComponents.dropFirst().first {
                        client.openSessionId = id
                    }
                }
        }
        .onChange(of: phase) { _, now in
            switch now {
            case .active:
                client.connect()
                client.setForeground(true)
                UNUserNotificationCenterBadgeReset.reset()
            case .background:
                client.setForeground(false)
            default: break
            }
        }
    }
}

import UserNotifications
enum UNUserNotificationCenterBadgeReset {
    static func reset() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}

struct RootView: View {
    @Environment(BridgeClient.self) private var client
    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            if client.pairing == nil {
                PairingView()
                    .transition(.opacity)
            } else {
                SessionsView()
                    .transition(.opacity)
            }
            ToastOverlay()
        }
        .animation(.easeInOut, value: client.pairing == nil)
        .foregroundStyle(Theme.text)
    }
}

struct ToastOverlay: View {
    @Environment(BridgeClient.self) private var client
    var body: some View {
        if let t = client.toast {
            HStack(spacing: 10) {
                Image(systemName: t.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(t.isError ? Theme.red : Theme.green)
                Text(t.text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 6)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(t.id)
            .task(id: t.id) {
                try? await Task.sleep(for: .seconds(t.text.count > 60 ? 5 : 2.2))
                withAnimation { if client.toast?.id == t.id { client.toast = nil } }
            }
            .onTapGesture { withAnimation { client.toast = nil } }
        }
    }
}
