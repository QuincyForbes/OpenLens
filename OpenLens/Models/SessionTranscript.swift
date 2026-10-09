import Foundation

/// Chat roles remain user/assistant. Context entries are independent records
/// in the server's chronological transcript, never synthetic chat messages.
nonisolated enum OCTranscriptEntry: Sendable {
    case message(OCMessageWithParts)
    case context(SessionContextEntry)

    var id: String {
        switch self {
        case .message(let message): message.id
        case .context(let entry): entry.id
        }
    }
}

struct SessionTranscript {
    let messages: [ChatMessage]
    let contextEntries: [SessionContextEntry]
    let entryOrder: [String]
}

nonisolated struct SessionContextEntry: Decodable, Identifiable, Sendable {
    enum Kind: String, Decodable, Sendable {
        case model = "model-switched"
        case agent = "agent-switched"
        case location = "location-switched"
        case system, skill, shell, compaction, idle
    }

    let id: String
    let kind: Kind
    let created: Double?
    let title: String
    let summary: String
    let details: String

    private enum CodingKeys: String, CodingKey {
        case id, type, time, model, previous, agent, location, description, text
        case name, command, status, exit, output, reason, summary, recent, error, outcome
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(Kind.self, forKey: .type)
        created = (try? values.decode(OCMessageTime.self, forKey: .time))?.created
        func text(_ key: CodingKeys) -> String {
            (try? values.decode(String.self, forKey: key)) ?? ""
        }
        func object(_ key: CodingKeys) -> [String: Any] {
            (try? values.decode(AnyCodable.self, forKey: key))?.value as? [String: Any] ?? [:]
        }
        func modelName(_ value: [String: Any]) -> String {
            let name = [value["providerID"] as? String, value["id"] as? String]
                .compactMap { $0 }.joined(separator: "/")
            return [name, value["variant"] as? String].compactMap { $0?.nilIfBlank }.joined(separator: " · ")
        }
        func joined(_ sections: [String]) -> String {
            sections.filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let status = text(.status)
        switch kind {
        case .model:
            title = "Model changed"
            summary = modelName(object(.model))
            let previous = modelName(object(.previous))
            details = previous.isEmpty ? "" : "Previously: \(previous)"
        case .agent:
            title = "Agent changed"
            summary = text(.agent)
            let previous = text(.previous)
            details = previous.isEmpty ? "" : "Previously: \(previous)"
        case .location:
            title = "Location changed"
            summary = object(.location)["directory"] as? String ?? ""
            let previous = (object(.previous)["location"] as? [String: Any])?["directory"] as? String ?? ""
            details = previous.isEmpty ? "" : "Previously: \(previous)"
        case .system:
            title = "System update"
            summary = text(.description)
            details = text(.text)
        case .skill:
            title = "Skill activated"
            summary = text(.name)
            details = text(.text)
        case .shell:
            title = joinedStatus("Shell", status: status)
            summary = text(.command)
            let exit = (try? values.decode(Int.self, forKey: .exit)).map { "Exit code: \($0)" } ?? ""
            // Retain unfamiliar structured output for inspection instead of
            // assuming it is stdout or silently dropping a usable result.
            let output = try? values.decode(AnyCodable.self, forKey: .output)
            let outputText: String
            if let string = output?.value as? String {
                outputText = string
            } else if let object = output?.value,
                      JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                outputText = String(decoding: data, as: UTF8.self)
            } else {
                outputText = ""
            }
            details = joined([exit, outputText])
        case .compaction:
            title = joinedStatus("Compaction", status: status)
            summary = text(.reason).capitalized
            let error = (try? values.decode(OCAPIError.self, forKey: .error))?.message ?? ""
            details = joined([text(.summary), text(.recent).isEmpty ? "" : "Recent context:\n\(text(.recent))", error])
        case .idle:
            switch text(.outcome) {
            case "succeeded": title = "Execution succeeded"
            case "failed": title = "Execution failed"
            case "interrupted": title = "Execution interrupted"
            default: title = "Execution ended"
            }
            summary = ""
            details = ""
        }
    }
}

private nonisolated func joinedStatus(_ title: String, status: String) -> String {
    status.isEmpty ? title : "\(title) · \(status.capitalized)"
}
