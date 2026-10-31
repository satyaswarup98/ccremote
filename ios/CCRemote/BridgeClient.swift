import Foundation
import Observation
import UIKit
import Network

@MainActor
@Observable
final class BridgeClient {
    enum Connection: Equatable { case disconnected, connecting, connected, failed(String) }

    private(set) var pairings: [Pairing]
    private(set) var activeId: String?
    var pairing: Pairing? { pairings.first { $0.id == activeId } ?? pairings.first }

    init() {
        let saved = PairingStore.load()
        pairings = saved.items
        activeId = saved.active
        // Moving between Wi-Fi and mobile data kills the socket; reconnect right away on the new network.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let kind = path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular" : "other"
            Task { @MainActor in self?.networkChanged(satisfied: path.status == .satisfied, kind: kind) }
        }
        pathMonitor.start(queue: .main)
    }

    private let pathMonitor = NWPathMonitor()
    private var networkKind: String?
    private var candidateIndex = 0
    private var connectingHost: String?

    private func networkChanged(satisfied: Bool, kind: String) {
        defer { networkKind = kind }
        guard satisfied, wantConnection, networkKind != nil, networkKind != kind || connection != .connected else { return }
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        candidateIndex = 0
        retry = 0
        connect()
    }

    // Last address that worked first, then every other address the Mac reported.
    private func candidates(_ p: Pairing) -> [String] {
        var out = [p.host]
        for h in p.hosts ?? [] where !out.contains(h) { out.append(h) }
        return out
    }

    private func updateActive(_ change: (inout Pairing) -> Void) {
        guard let i = pairings.firstIndex(where: { $0.id == pairing?.id }) else { return }
        var p = pairings[i]
        change(&p)
        if p != pairings[i] { pairings[i] = p; persist() }
    }

    private func persist() {
        PairingStore.save(.init(active: pairing?.id, items: pairings))
    }
    private(set) var connection: Connection = .disconnected
    private(set) var state: BridgeState?
    private(set) var items: [TranscriptItem] = []
    private(set) var screen: String = ""
    private(set) var recentDirs: [String] = []
    private(set) var notifications: [NotificationItem] = []
    // Messages sent from this phone, shown straight away and updated as the Mac reports back.
    private(set) var outgoing: [Outgoing] = []

    struct Outgoing: Identifiable, Equatable {
        enum Status: String { case sending, sent, queued, failed }
        let id: String
        let sessionId: String
        let text: String
        var status: Status
        var note: String?
    }

    func outgoing(for sessionId: String) -> [Outgoing] { outgoing.filter { $0.sessionId == sessionId } }

    func retry(_ o: Outgoing) {
        guard let i = outgoing.firstIndex(where: { $0.id == o.id }) else { return }
        outgoing[i].status = .sending
        outgoing[i].note = nil
        send(["t": "send", "sessionId": o.sessionId, "text": o.text, "mode": "auto", "clientId": o.id])
    }

    func dismissOutgoing(_ o: Outgoing) { outgoing.removeAll { $0.id == o.id } }

    private static func norm(_ t: String) -> String {
        t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Once the message shows up in the chat itself, the local copy isn't needed any more.
    private func reconcileOutgoing(with newItems: [TranscriptItem], sessionId: String) {
        let arrived = newItems.filter { $0.kind == "user" }.map { Self.norm($0.text ?? "") }
        guard !arrived.isEmpty else { return }
        outgoing.removeAll { o in
            o.sessionId == sessionId && o.status != .failed && arrived.contains { $0.contains(Self.norm(o.text).prefix(200)) }
        }
    }
    private(set) var notificationsSeenAt: Double = 0
    var hasUnreadNotifications: Bool { (notifications.first?.at ?? 0) > notificationsSeenAt }
    var toast: Toast?
    // Set by notification taps / deep links; the session list navigates to it.
    var openSessionId: String?

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var subscribed: String?
    private var retry = 0
    private var wantConnection = false
    private var seenPending = Set<String>()

    var sessions: [SessionInfo] { state?.sessions ?? [] }
    var pending: [PendingRequest] { state?.pending ?? [] }
    func pending(for sessionId: String) -> [PendingRequest] { pending.filter { $0.sessionId == sessionId } }
    func session(_ id: String) -> SessionInfo? { sessions.first { $0.id == id } }

    // MARK: Pairing

    func pair(host: String, port: Int, code: String) async throws {
        let delegate = PinningDelegate(expected: nil)
        let s = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        let base = "https://\(Self.urlHost(host)):\(port)"

        // First request only learns the certificate; the proof binds the code to it.
        var info = URLRequest(url: URL(string: "\(base)/info")!)
        info.timeoutInterval = 6
        let (infoData, _) = try await s.data(for: info)
        guard (try? JSONSerialization.jsonObject(with: infoData) as? [String: Any])?["app"] as? String == "ccremote",
              let fp = delegate.seenFingerprint else {
            throw PairError.message("That address isn't a CC Remote bridge.")
        }

        var req = URLRequest(url: URL(string: "\(base)/pair")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "proof": PairingProof.make(code: code, fingerprint: fp),
            "deviceName": UIDevice.current.name,
        ])
        let (data, resp) = try await s.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, delegate.seenFingerprint == fp,
              let token = obj["token"] as? String else {
            throw PairError.message(obj["error"] as? String ?? "Pairing failed.")
        }
        let p = Pairing(host: host, port: port, token: token, fingerprint: fp,
                        macName: obj["macName"] as? String ?? "Mac", deviceId: obj["deviceId"] as? String ?? "")
        // Re-pairing the same Mac replaces its old entry.
        pairings.removeAll { $0.id == p.id }
        pairings.append(p)
        switchTo(p.id)
    }

    func switchTo(_ id: String) {
        guard pairings.contains(where: { $0.id == id }) else { return }
        disconnect()
        activeId = id
        persist()
        state = nil
        items = []
        screen = ""
        subscribed = nil
        seenPending = []
        notifications = []
        connect()
    }

    // Forgets one Mac on this phone (default: the active one) and moves to the next.
    func unpair(_ id: String? = nil) {
        let target = id ?? pairing?.id
        let wasActive = target == pairing?.id
        pairings.removeAll { $0.id == target }
        if wasActive {
            disconnect()
            state = nil
            activeId = pairings.first?.id
            persist()
            if pairing != nil { connect() }
        } else {
            persist()
        }
    }

    func updateHost(_ host: String, port: Int) {
        guard let i = pairings.firstIndex(where: { $0.id == pairing?.id }) else { return }
        pairings[i].host = host
        pairings[i].port = port
        persist()
        disconnect()
        connect()
    }

    enum PairError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    // MARK: Connection

    func connect() {
        guard let p = pairing else { return }
        wantConnection = true
        guard socket == nil else { return }
        connection = .connecting
        let hosts = candidates(p)
        let host = hosts[candidateIndex % hosts.count]
        connectingHost = host
        let s = URLSession(configuration: .default, delegate: PinningDelegate(expected: p.fingerprint), delegateQueue: nil)
        var req = URLRequest(url: URL(string: "wss://\(Self.urlHost(host)):\(p.port)/ws")!)
        req.setValue("Bearer \(p.token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        let task = s.webSocketTask(with: req)
        session = s
        socket = task
        task.resume()
        receive(task)
        send(["t": "fg", "value": true])
        loadNotifications()
        if let subscribed { send(["t": "subscribe", "sessionId": subscribed]) }
    }

    func disconnect() {
        wantConnection = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        connection = .disconnected
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    if self.connection != .connected {
                        self.connection = .connected
                        self.retry = 0
                        self.candidateIndex = 0
                        // Remember which address worked, so it's tried first next time.
                        if let h = self.connectingHost { self.updateActive { $0.host = h } }
                    }
                    if case .string(let text) = message { self.handle(Data(text.utf8)) }
                    if case .data(let data) = message { self.handle(data) }
                    self.receive(task)
                case .failure(let error):
                    self.socketDied(error, closeCode: task.closeCode.rawValue)
                }
            }
        }
    }

    private func socketDied(_ error: Error, closeCode: Int) {
        socket = nil
        session?.invalidateAndCancel()
        session = nil
        if closeCode == 4001 {
            connection = .failed("This iPhone was unpaired on the Mac.")
            return
        }
        connection = .failed(Self.describe(error))
        guard wantConnection else { return }
        // Try the Mac's other local addresses before backing off.
        if let p = pairing, candidateIndex + 1 < candidates(p).count {
            candidateIndex += 1
            connection = .connecting
            connect()
            return
        }
        candidateIndex = 0
        retry += 1
        let delay = min(Double(1 << min(retry, 4)), 15)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            if self.wantConnection && self.socket == nil { self.connect() }
        }
    }

    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
            return "Can't reach the Mac. Same Wi-Fi? Is the bridge running (ccr status)?"
        case NSURLErrorCancelled:
            // Our pinning check cancels the connection when the certificate isn't this Mac's.
            return "Something other than your Mac answered, or the Mac's security key changed. If it keeps happening, re-pair from Settings."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed:
            return "Couldn't make a secure connection to the Mac. Check that it's on and on the same Wi-Fi."
        case NSURLErrorBadServerResponse:
            return "The Mac refused this iPhone. Re-pair from Settings."
        default:
            return ns.localizedDescription
        }
    }

    private func handle(_ data: Data) {
        guard let head = try? JSONDecoder().decode(Head.self, from: data) else { return }
        let dec = JSONDecoder()
        switch head.t {
        case "state":
            guard let s = try? dec.decode(BridgeState.self, from: data) else { return }
            let newOnes = s.pending.filter { !seenPending.contains($0.id) }
            seenPending = Set(s.pending.map(\.id))
            state = s
            if let addrs = s.addresses?.map(\.address), !addrs.isEmpty {
                updateActive { $0.hosts = addrs }
            }
            if !newOnes.isEmpty { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        case "items":
            guard let m = try? dec.decode(ItemsMsg.self, from: data), m.sessionId == subscribed else { return }
            if m.reset { items = m.items } else {
                let known = Set(items.map(\.id))
                items.append(contentsOf: m.items.filter { !known.contains($0.id) })
            }
            reconcileOutgoing(with: m.items, sessionId: m.sessionId)
            if items.count > 500 { items.removeFirst(items.count - 500) }
        case "screen":
            guard let m = try? dec.decode(ScreenMsg.self, from: data), m.sessionId == subscribed else { return }
            screen = m.text
        case "toast":
            guard let m = try? dec.decode(ToastMsg.self, from: data) else { return }
            toast = Toast(text: m.text, isError: m.level == "error")
        case "event":
            guard let m = try? dec.decode(EventMsg.self, from: data) else { return }
            if let item = m.item { addNotification(item) }
            // Don't banner the session you're already looking at, except for things that need you.
            let needsYou = m.kind == "permission" || m.kind == "question" || m.kind == "stop"
            if m.sessionId != subscribed || needsYou {
                Notifier.shared.banner(m.title, subtitle: m.subtitle, body: m.body, sessionId: m.sessionId,
                                       approvalId: m.kind == "permission" && m.answerable ? m.requestId : nil)
            }
        case "opened":
            guard let m = try? dec.decode(OpenedMsg.self, from: data) else { return }
            openSessionId = m.sessionId
        case "sendResult":
            guard let m = try? dec.decode(SendResultMsg.self, from: data),
                  let i = outgoing.firstIndex(where: { $0.id == m.clientId }) else { return }
            outgoing[i].status = Outgoing.Status(rawValue: m.status) ?? .sent
            outgoing[i].note = m.note
            if outgoing[i].status == .failed { UINotificationFeedbackGenerator().notificationOccurred(.error) }
        case "notifications":
            guard let m = try? dec.decode(NotificationsMsg.self, from: data) else { return }
            notifications = m.items
        case "notification":
            guard let m = try? dec.decode(NotificationMsg.self, from: data) else { return }
            addNotification(m.item)
        case "recentDirs":
            guard let m = try? dec.decode(DirsMsg.self, from: data) else { return }
            recentDirs = m.dirs
        default: break
        }
    }

    private struct Head: Decodable { let t: String }
    private struct ItemsMsg: Decodable { let sessionId: String; let items: [TranscriptItem]; let reset: Bool }
    private struct ScreenMsg: Decodable { let sessionId: String; let text: String }
    private struct ToastMsg: Decodable { let text: String; let level: String? }
    private struct DirsMsg: Decodable { let dirs: [String] }
    private struct EventMsg: Decodable {
        let kind: String; let sessionId: String; let requestId: String?
        let title: String; let subtitle: String; let body: String; let answerable: Bool
        let item: NotificationItem?
    }
    private struct NotificationsMsg: Decodable { let items: [NotificationItem] }
    private struct SendResultMsg: Decodable { let clientId: String; let status: String; let note: String? }
    private struct NotificationMsg: Decodable { let item: NotificationItem }

    private func addNotification(_ item: NotificationItem) {
        guard !notifications.contains(where: { $0.id == item.id }) else { return }
        notifications.insert(item, at: 0)
        if notifications.count > 200 { notifications.removeLast(notifications.count - 200) }
    }

    private var seenKey: String { "notificationsSeenAt-\(pairing?.id ?? "")" }

    func loadNotifications() {
        notificationsSeenAt = UserDefaults.standard.double(forKey: seenKey)
        send(["t": "notifications"])
    }

    func markNotificationsSeen() {
        notificationsSeenAt = notifications.first?.at ?? notificationsSeenAt
        UserDefaults.standard.set(notificationsSeenAt, forKey: seenKey)
    }
    private struct OpenedMsg: Decodable { let sessionId: String }

    private func send(_ obj: [String: Any]) {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        socket.send(.string(text)) { _ in }
    }

    // MARK: Commands

    func setForeground(_ fg: Bool) { send(["t": "fg", "value": fg]) }

    func subscribe(_ sessionId: String) {
        if subscribed != sessionId { items = []; screen = "" }
        subscribed = sessionId
        send(["t": "subscribe", "sessionId": sessionId])
    }

    func unsubscribe(_ sessionId: String) {
        guard subscribed == sessionId else { return }
        subscribed = nil
        send(["t": "unsubscribe"])
    }

    enum SendMode: String { case auto, vscode, fork, queue }

    func sendText(_ text: String, to sessionId: String, mode: SendMode = .auto) {
        let id = UUID().uuidString
        outgoing.append(Outgoing(id: id, sessionId: sessionId, text: text, status: connection == .connected ? .sending : .failed,
                                 note: connection == .connected ? nil : "Not connected to the Mac"))
        guard connection == .connected else { return }
        send(["t": "send", "sessionId": sessionId, "text": text, "mode": mode.rawValue, "clientId": id])
    }

    func sendKeys(_ keys: [String], to sessionId: String) {
        send(["t": "keys", "sessionId": sessionId, "keys": keys])
    }

    func clearQueue(_ sessionId: String) { send(["t": "unqueue", "sessionId": sessionId]) }

    func allow(_ req: PendingRequest, suggestion: Int? = nil) {
        var m: [String: Any] = ["t": "decide", "requestId": req.id, "behavior": "allow"]
        if let suggestion { m["suggestion"] = suggestion }
        send(m)
    }

    func deny(_ req: PendingRequest, message: String?, interrupt: Bool = false) {
        var m: [String: Any] = ["t": "decide", "requestId": req.id, "behavior": "deny", "interrupt": interrupt]
        if let message, !message.isEmpty { m["message"] = message }
        send(m)
    }

    // From the Allow / Deny buttons on a notification.
    func decide(requestId: String, allow: Bool) {
        if allow { send(["t": "decide", "requestId": requestId, "behavior": "allow"]) }
        else { send(["t": "decide", "requestId": requestId, "behavior": "deny"]) }
    }

    func answer(_ req: PendingRequest, answers: [String: String]) {
        send(["t": "decide", "requestId": req.id, "answers": answers])
    }

    func answerOnMac(_ req: PendingRequest) {
        send(["t": "decide", "requestId": req.id, "behavior": "release"])
    }

    func loadRecentDirs() { send(["t": "recentDirs"]) }
    func newSession(cwd: String, text: String) { send(["t": "newSession", "cwd": cwd, "text": text, "target": "vscode"]) }

    static func urlHost(_ host: String) -> String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }
}
