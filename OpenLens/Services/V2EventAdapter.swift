import Foundation

/// Translates the native v2 event vocabulary into the existing bounded chat
/// reducers. Owned by SSEClient's serial queue; reset on every stream change.
nonisolated struct V2EventAdapter {
    private var tools: [String: [String: Any]] = [:]
    private static let maximumTools = 256
    /// Emitted when a session's pending inbox changed but its transcript did not.
    static let inboxChangedEventType = "session.inbox.changed"
    static let viewedChangedEventType = "session.viewed.changed"

    private static let contentEvents: Set<String> = [
        "session.step.started", "session.step.streamed", "session.step.ended", "session.step.failed",
        "session.text.started", "session.text.delta", "session.text.ended",
        "session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended",
        "session.tool.input.started", "session.tool.input.delta", "session.tool.input.ended",
        "session.tool.called", "session.tool.progress", "session.tool.success", "session.tool.failed"
    ]

    mutating func event(_ envelope: [String: Any], directory: String?) throws -> OCEvent? {
        guard let type = envelope["type"] as? String,
              let data = envelope["data"] as? [String: Any] else {
            throw OpenCodeError.invalidPayload("Invalid native v2 event.")
        }
        if type == "server.connected" || type == "server.heartbeat" {
            return OCEvent(type: type, properties: AnyCodable([String: String]()))
        }
        // A move can be published from its destination. Let the open chat
        // reconcile by identity across the directory filter; only REST may
        // choose and authorize the new workspace, never the event payload.
        if type == "session.moved" {
            guard let sessionID = data["sessionID"] as? String,
                  StreamDisplayValue.fitsIdentifier(sessionID) else {
                throw OpenCodeError.invalidPayload("Invalid native v2 move identity.")
            }
            return OCEvent(type: "session.reconcile", properties: AnyCodable([
                "sessionID": sessionID, "locationChanged": true
            ]))
        }
        if let directory {
            guard let location = envelope["location"] as? [String: Any],
                  let eventDirectory = location["directory"] as? String else {
                throw OpenCodeError.invalidPayload("Native v2 event has no location.")
            }
            guard WorkspaceSelectionBuilder.normalizedDirectory(eventDirectory)
                    == WorkspaceSelectionBuilder.normalizedDirectory(directory) else {
                return nil
            }
        }
        func make(_ name: String, _ payload: [String: Any]) -> OCEvent {
            OCEvent(type: name, properties: AnyCodable(payload))
        }
        func reconcile() -> OCEvent { make("session.reconcile", data) }

        switch type {
        case "permission.asked", "form.created", "form.replied", "form.cancelled", "session.status":
            return make(type, data)
        // Inbox changes outside delivery leave the transcript as it is, so
        // only the queue is read again.
        case "session.inbox.enqueued", "session.inbox.cancelled", "session.inbox.delivery.changed":
            guard let sessionID = data["sessionID"] as? String else { return reconcile() }
            return make(Self.inboxChangedEventType, ["sessionID": sessionID])
        case "session.viewed":
            guard let sessionID = data["sessionID"] as? String, StreamDisplayValue.fitsIdentifier(sessionID) else {
                throw OpenCodeError.invalidPayload("Invalid native v2 viewed identity.")
            }
            return make(Self.viewedChangedEventType, ["sessionID": sessionID])
        case "permission.replied", "session.inbox.delivered",
             "session.execution.succeeded", "session.execution.failed", "session.execution.interrupted",
             "session.revert.committed", "session.revert.staged", "session.revert.cleared",
             "session.message.content.updated", "session.deleted", "session.idle",
             "session.instructions.updated", "session.skill.activated", "session.synthetic",
             "session.shell.started", "session.shell.ended",
             "session.compaction.started", "session.compaction.ended", "session.compaction.failed":
            return reconcile()
        case "session.execution.started":
            guard let sessionID = data["sessionID"] as? String else { return reconcile() }
            return make("session.status", ["sessionID": sessionID, "status": ["type": "busy"]])
        case "session.renamed":
            guard let sessionID = data["sessionID"] as? String, let title = data["title"] as? String else { return reconcile() }
            return make("session.updated", ["info": ["id": sessionID, "title": title]])
        // Explicit switches from any client change the session's canonical
        // selection. Merge that field immediately; the chat then refreshes
        // history to retrieve the switch record's canonical identity/order.
        case "session.model.selected":
            guard let sessionID = data["sessionID"] as? String,
                  let model = data["model"] as? [String: Any],
                  model["id"] is String, model["providerID"] is String else { return reconcile() }
            return make("session.updated", ["info": ["id": sessionID, "model": model, "v2ContextChanged": true]])
        case "session.agent.selected":
            guard let sessionID = data["sessionID"] as? String,
                  let agent = data["agent"] as? String else { return reconcile() }
            return make("session.updated", ["info": ["id": sessionID, "agent": agent, "v2ContextChanged": true]])
        case "location.shutdown", "location.disposed", "location.reloaded":
            tools.removeAll()
            return make("session.reconcile", [:])
        default:
            break
        }

        guard Self.contentEvents.contains(type) else {
            return make(type, data)
        }
        guard let sessionID = data["sessionID"] as? String,
              let messageID = data["assistantMessageID"] as? String,
              StreamDisplayValue.fitsIdentifier(sessionID), StreamDisplayValue.fitsIdentifier(messageID) else {
            throw OpenCodeError.invalidPayload("Invalid native v2 message identity.")
        }
        if type.hasPrefix("session.step.") {
            if type == "session.step.failed" { return reconcile() }
            var info: [String: Any] = ["id": messageID, "sessionID": sessionID, "role": "assistant"]
            for key in ["agent", "cost", "tokens", "finish"] { info[key] = data[key] }
            info["v2StepCompleted"] = type == "session.step.ended"
            if let model = data["model"] as? [String: Any] {
                info["modelID"] = model["id"]
                info["providerID"] = model["providerID"]
            }
            return make("message.updated", ["info": info])
        }
        if type.hasPrefix("session.text.") || type.hasPrefix("session.reasoning.") {
            guard let ordinal = data["ordinal"] as? Int, ordinal >= 0 else {
                throw OpenCodeError.invalidPayload("Invalid native v2 content ordinal.")
            }
            let partID = "\(messageID)-\(ordinal)"
            if type.hasSuffix(".delta") {
                guard let delta = data["delta"] as? String else { throw OpenCodeError.invalidPayload("Invalid v2 delta.") }
                return make("message.part.delta", ["sessionID": sessionID, "messageID": messageID, "partID": partID, "field": "text", "delta": delta])
            }
            return make("message.part.updated", ["part": [
                "id": partID, "sessionID": sessionID, "messageID": messageID,
                "type": type.hasPrefix("session.reasoning.") ? "reasoning" : "text",
                "text": data["text"] as? String ?? ""
            ]])
        }
        guard let id = data["id"] as? String, StreamDisplayValue.fitsIdentifier(id) else {
            throw OpenCodeError.invalidPayload("Invalid native v2 tool identity.")
        }
        let key = "\(sessionID)/\(messageID)/\(id)"
        if type == "session.tool.input.started" {
            guard tools.count < Self.maximumTools, let name = data["name"] as? String else {
                throw OpenCodeError.invalidPayload("Native v2 tool buffer is full or malformed.")
            }
            tools[key] = ["name": name, "state": ["status": "pending"]]
        }
        guard var tool = tools[key], var state = tool["state"] as? [String: Any] else {
            // A stream can begin after the tool-name event. REST is authoritative.
            return reconcile()
        }
        switch type {
        case "session.tool.input.delta", "session.tool.input.ended":
            // Partial JSON is not displayable input; called carries the parsed object.
            return nil
        case "session.tool.called":
            state["status"] = "running"
            state["input"] = data["input"]
        case "session.tool.progress":
            state["metadata"] = data["metadata"]
        case "session.tool.success", "session.tool.failed":
            state["status"] = type.hasSuffix("success") ? "completed" : "error"
            state["content"] = data["content"]
            state["error"] = data["error"]
            state["metadata"] = data["metadata"]
        default:
            break
        }
        let decodedState = try JSONDecoder().decode(OCToolState.self, from: JSONSerialization.data(withJSONObject: state))
        let safePart = StreamToolPartSafety.sanitize(OCPart(
            id: id, sessionID: sessionID, messageID: messageID, type: .tool,
            callID: id, tool: tool["name"] as? String, state: decodedState
        ))
        var toolPart: [String: Any] = [
            "id": safePart.id,
            "sessionID": safePart.sessionID,
            "messageID": safePart.messageID,
            "type": "tool",
            "callID": safePart.callID ?? id,
        ]
        if let name = safePart.tool { toolPart["tool"] = name }
        if let safeState = safePart.state,
           let stateObj = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(safeState)) as? [String: Any] {
            toolPart["state"] = stateObj
        }
        // Retain only the same bounded fields used by chat, never raw tool input.
        tool["name"] = safePart.tool
        tool["state"] = toolPart["state"]
        if type == "session.tool.success" || type == "session.tool.failed" {
            tools.removeValue(forKey: key)
        } else {
            tools[key] = tool
        }
        return make("message.part.updated", ["part": toolPart, "preparedPart": safePart])
    }
}
