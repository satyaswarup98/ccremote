import Foundation
import Network
import Observation

// Finds bridges advertised as _ccremote._tcp on the local network and resolves them to IPv4 host:port.
@MainActor
@Observable
final class Discovery {
    struct Found: Identifiable, Hashable {
        let name: String
        let host: String
        let port: Int
        var id: String { name }
    }

    private(set) var found: [Found] = []
    private(set) var browsing = false
    private var browser: NWBrowser?
    private var resolvers: [String: NWConnection] = [:]

    func start() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: "_ccremote._tcp", domain: "local."), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.update(results) }
        }
        b.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.browsing = (state == .ready) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        resolvers.values.forEach { $0.cancel() }
        resolvers = [:]
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let names = Set(results.compactMap { r -> String? in
            if case .service(let name, _, _, _) = r.endpoint { return name }
            return nil
        })
        found.removeAll { !names.contains($0.name) }
        for r in results {
            guard case .service(let name, _, _, _) = r.endpoint,
                  resolvers[name] == nil, !found.contains(where: { $0.name == name }) else { continue }
            resolve(name: name, endpoint: r.endpoint)
        }
    }

    private func resolve(name: String, endpoint: NWEndpoint) {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let conn = NWConnection(to: endpoint, using: params)
        resolvers[name] = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    if case .hostPort(let host, let port) = conn.currentPath?.remoteEndpoint {
                        var h = "\(host)"
                        if let pct = h.firstIndex(of: "%") { h = String(h[..<pct]) }
                        let display = name.replacingOccurrences(of: "CC Remote on ", with: "")
                        self.found.append(Found(name: display, host: h, port: Int(port.rawValue)))
                    }
                    conn.cancel()
                    self.resolvers[name] = nil
                case .failed, .cancelled:
                    self.resolvers[name] = nil
                default: break
                }
            }
        }
        conn.start(queue: .main)
    }
}
