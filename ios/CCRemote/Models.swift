import Foundation

struct BridgeState: Decodable {
    let mac: String
    let away: Bool
    let locked: Bool?
    let awayMode: String
    let idleThresholdSec: Int
    let ntfyTopic: String?
    let ntfyServer: String?
    let port: Int?
    let addresses: [BridgeAddress]?
    let sessions: [SessionInfo]
    let pending: [PendingRequest]
}

enum SessionStatus: String, Decodable {
    case working, idle, ended
    case needsPermission = "needs_permission"
    case needsAnswer = "needs_answer"
    case waitingInput = "waiting_input"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .unknown
    }

    var label: String {
        switch self {
        case .working: "Working"
        case .idle: "Idle"
        case .ended: "Ended"
        case .needsPermission: "Needs approval"
        case .needsAnswer: "Has a question"
        case .waitingInput: "Waiting for you"
        case .unknown: "—"
        }
    }

    var shortLabel: String {
        switch self {
        case .needsPermission: "Approve"
        case .needsAnswer: "Question"
        case .waitingInput: "Waiting"
        default: label
        }
    }

    var needsYou: Bool { self == .needsPermission || self == .needsAnswer || self == .waitingInput }
}

struct SessionInfo: Decodable, Identifiable, Hashable {
    let id: String
    let cwd: String?
    let project: String
    let title: String?
    let entrypoint: String
    let hasMirror: Bool
    let status: SessionStatus
    let activity: String?
    let lastMessage: String?
    let lastPrompt: String?
    let permissionMode: String?
    let updatedAt: Double
    let queued: Int
    let holdingForPhone: Bool

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
    var displayTitle: String { title ?? lastPrompt ?? "New session" }
    var isVSCode: Bool { entrypoint.contains("vscode") }

    static func == (a: SessionInfo, b: SessionInfo) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

struct PermissionDetail: Decodable, Hashable {
    let type: String
    let file: String?
    let old: String?
    let new: String?
    let text: String?
    let description: String?
}

struct Suggestion: Decodable, Hashable, Identifiable {
    let index: Int
    let label: String
    var id: Int { index }
}

struct QuestionOption: Decodable, Hashable {
    let label: String
    let description: String?
}

struct Question: Decodable, Hashable, Identifiable {
    let question: String
    let header: String?
    let options: [QuestionOption]
    let multiSelect: Bool?
    var id: String { question }
}

struct PendingRequest: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String          // permission | question
    let sessionId: String
    let project: String
    let toolName: String?
    let summary: String?
    let detail: PermissionDetail?
    let suggestions: [Suggestion]?
    let answerable: Bool?
    let questions: [Question]?
    let createdAt: Double

    var isQuestion: Bool { kind == "question" }
    var canAnswerFromPhone: Bool { isQuestion || (answerable ?? false) }
}

struct TranscriptItem: Decodable, Identifiable, Hashable {
    let id: String
    let kind: String          // user | assistant | tool | result
    let text: String?
    let name: String?
    let summary: String?
    let toolUseId: String?
    let isError: Bool?
    let fromPhone: Bool?
}

struct BridgeAddress: Decodable, Hashable {
    let address: String
    let kind: String
}

struct Pairing: Codable, Equatable, Identifiable {
    var host: String
    var port: Int
    var token: String
    var fingerprint: String
    var macName: String
    var deviceId: String
    // Every local address the Mac has reported, tried in turn when one fails.
    var hosts: [String]? = nil

    // The certificate fingerprint identifies a Mac's bridge.
    var id: String { fingerprint }

    var securityCode: String {
        let f = Array(fingerprint)
        return stride(from: 0, to: 12, by: 4).map { String(f[$0..<$0 + 4]) }.joined(separator: " ")
    }
}

struct NotificationItem: Decodable, Identifiable, Hashable {
    let id: String
    let at: Double
    let kind: String          // permission | question | stop | done | waiting | notice
    let sessionId: String
    let title: String
    let subtitle: String
    let body: String

    var date: Date { Date(timeIntervalSince1970: at / 1000) }
}
