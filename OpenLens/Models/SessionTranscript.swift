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
        case system, skill, shell, compaction, idle, synthetic
    }

    let id: String
    let kind: Kind
    let created: Double?
    let title: String
    let summary: String
    let details: String
    let subagentResult: SubagentResult?

    nonisolated struct SubagentResult: Sendable {
        let childID: String?
        let agent: String?
        let state: SubagentResultState?

        init(metadata: [String: Any]) {
            let child = metadata["childID"] as? String
            childID = child.flatMap { InteractiveFormSafety.fitsIdentifier($0) ? $0 : nil }
            agent = StreamDisplayValue.preview(metadata["agent"] as? String, maximumBytes: 128)?.nilIfBlank
            state = (metadata["state"] as? String).flatMap(SubagentResultState.init(rawValue:))
        }
    }

    static let maximumDetailCharacters = 40_000

    private enum CodingKeys: String, CodingKey {
        case id, type, time, model, previous, agent, location, description, text
        case name, command, status, exit, output, reason, summary, recent, error, outcome, metadata
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
        let metadata = object(.metadata)
        subagentResult = kind == .synthetic && metadata["source"] as? String == "subagent"
            ? SubagentResult(metadata: metadata) : nil
        let status = text(.status)
        let fullDetails: String
        var outputWasTruncated = false
        switch kind {
        case .model:
            title = "Model changed"
            summary = modelName(object(.model))
            let previous = modelName(object(.previous))
            fullDetails = previous.isEmpty ? "" : "Previously: \(previous)"
        case .agent:
            title = "Agent changed"
            summary = text(.agent)
            let previous = text(.previous)
            fullDetails = previous.isEmpty ? "" : "Previously: \(previous)"
        case .location:
            title = "Location changed"
            summary = object(.location)["directory"] as? String ?? ""
            let previous = (object(.previous)["location"] as? [String: Any])?["directory"] as? String ?? ""
            fullDetails = previous.isEmpty ? "" : "Previously: \(previous)"
        case .system:
            title = "System update"
            summary = text(.description)
            fullDetails = text(.text)
        case .skill:
            title = "Skill activated"
            summary = text(.name)
            fullDetails = text(.text)
        case .shell:
            title = joinedStatus("Shell", status: status)
            summary = text(.command)
            let exit = (try? values.decode(Int.self, forKey: .exit)).map { "Exit code: \($0)" } ?? ""
            let output = try? values.decode(AnyCodable.self, forKey: .output)
            let outputText: String
            if let string = output?.value as? String {
                outputText = string
            } else if let object = output?.value as? [String: Any], let string = object["text"] as? String {
                outputWasTruncated = object["truncated"] as? Bool == true
                outputText = joined([string, outputWasTruncated ? "Output truncated." : ""])
            } else if let object = output?.value,
                      JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
                outputText = String(decoding: data, as: UTF8.self)
            } else {
                outputText = ""
            }
            fullDetails = joined([exit, outputText])
        case .compaction:
            title = joinedStatus("Compaction", status: status)
            summary = text(.reason).capitalized
            let error = (try? values.decode(OCAPIError.self, forKey: .error))?.message ?? ""
            fullDetails = joined([text(.summary), text(.recent).isEmpty ? "" : "Recent context:\n\(text(.recent))", error])
        case .synthetic:
            title = subagentResult.map { "Subagent · \($0.state?.title ?? "Result")" } ?? "Session update"
            summary = [subagentResult?.agent, text(.description).nilIfBlank]
                .compactMap { $0 }.joined(separator: " · ")
            let resultText = text(.text)
            // Released background delivery wraps the readable text in one
            // subagent envelope. Only unwrap that exact outer shape.
            if subagentResult != nil, resultText.hasPrefix("<subagent "),
               let newline = resultText.firstIndex(of: "\n"), resultText.hasSuffix("\n</subagent>") {
                fullDetails = String(resultText[resultText.index(after: newline)...].dropLast("\n</subagent>".count))
            } else {
                fullDetails = resultText
            }
        case .idle:
            switch text(.outcome) {
            case "succeeded": title = "Execution succeeded"
            case "failed": title = "Execution failed"
            case "interrupted": title = "Execution interrupted"
            default: title = "Execution ended"
            }
            summary = ""
            fullDetails = ""
        }
        if fullDetails.count > Self.maximumDetailCharacters {
            let notice = "\n\n" + joined(["Preview shortened.", outputWasTruncated ? "Output truncated." : ""])
            details = String(fullDetails.prefix(Self.maximumDetailCharacters - notice.count)) + notice
        } else {
            details = fullDetails
        }
    }
}

private nonisolated func joinedStatus(_ title: String, status: String) -> String {
    status.isEmpty ? title : "\(title) · \(status.capitalized)"
}

/// Terminal background-job states, independent of launch-tool completion.
nonisolated enum SubagentResultState: String, Sendable {
    case completed, error, cancelled

    var title: String {
        switch self {
        case .completed: "Completed"
        case .error: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}
