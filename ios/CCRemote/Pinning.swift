import Foundation
import CryptoKit
import Security

// The bridge uses a self-signed certificate. We pin its SHA-256 (of the DER bytes):
// during pairing we record whatever the Mac presents, afterwards only that exact cert is accepted.
final class PinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let expected: String?
    private let lock = NSLock()
    private var _seen: String?

    init(expected: String?) {
        self.expected = expected
    }

    var seenFingerprint: String? {
        lock.lock(); defer { lock.unlock() }
        return _seen
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let fp = Self.fingerprint(leaf)
        lock.lock(); _seen = fp; lock.unlock()
        if let expected, expected != fp {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    static func fingerprint(_ cert: SecCertificate) -> String {
        let der = SecCertificateCopyData(cert) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

enum PairingProof {
    // Must match the bridge: HMAC-SHA256(key = code, message = fingerprint hex)
    static func make(code: String, fingerprint: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(fingerprint.utf8), using: SymmetricKey(data: Data(code.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
