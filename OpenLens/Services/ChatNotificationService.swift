import Foundation
import UIKit
import UserNotifications

/// Schedules local iOS notifications when a user asks to be reminded in chat
/// (e.g., "remind us when this finishes", "remind me in 10 minutes") or toggles
/// completion notifications for a running agent or background task.
final class ChatNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ChatNotificationService()

    private let center = UNUserNotificationCenter.current()
    private var hasConfiguredDelegate = false

    private override init() {
        super.init()
    }

    func configureIfNeeded() {
        guard !hasConfiguredDelegate else { return }
        hasConfiguredDelegate = true
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        configureIfNeeded()
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    /// Detects natural-language requests in a chat prompt asking for a reminder or notification.
    nonisolated static func containsReminderRequest(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let triggers = [
            "remind me",
            "remind us",
            "notify me",
            "notify us",
            "ping me",
            "ping us",
            "alert me",
            "alert us",
            "let me know when",
            "let us know when",
            "send a notification",
            "send me a notification"
        ]
        return triggers.contains { lowered.contains($0) }
    }

    /// Parses an optional relative time delay such as "in 5 minutes", "in 2 hours", or "in 30s".
    nonisolated static func parseRelativeReminderDelaySeconds(from text: String) -> TimeInterval? {
        guard containsReminderRequest(text) else { return nil }
        let pattern = #"\bin\s+(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let amountRange = Range(match.range(at: 1), in: text),
              let unitRange = Range(match.range(at: 2), in: text),
              let amount = Double(text[amountRange]),
              amount > 0 else {
            return nil
        }

        let unit = text[unitRange].lowercased()
        if unit.hasPrefix("h") {
            return min(amount * 3600, 86_400)
        } else if unit.hasPrefix("m") {
            return min(amount * 60, 86_400)
        } else {
            return max(5, min(amount, 86_400))
        }
    }

    @discardableResult
    func scheduleTimedReminderIfPresent(
        in promptText: String,
        sessionID: String?,
        sessionTitle: String?
    ) -> TimeInterval? {
        guard let delay = Self.parseRelativeReminderDelaySeconds(from: promptText) else {
            return nil
        }
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        let titleSuffix = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = (titleSuffix?.isEmpty == false)
            ? "Reminder · \(titleSuffix!)"
            : "OpenLens Reminder"
        content.body = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        content.sound = .default
        if let sessionID {
            content.userInfo = ["sessionID": sessionID]
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        let request = UNNotificationRequest(
            identifier: "openlens.timed-reminder.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
        return delay
    }

    func scheduleTurnCompletionNotification(
        sessionID: String?,
        sessionTitle: String?,
        preview: String,
        isBackgroundWatcherCompletion: Bool = false
    ) {
        requestAuthorizationIfNeeded()

        let content = UNMutableNotificationContent()
        let cleanTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBackgroundWatcherCompletion {
            content.title = (cleanTitle?.isEmpty == false)
                ? "Background Task Finished · \(cleanTitle!)"
                : "Background Task Finished"
        } else {
            content.title = (cleanTitle?.isEmpty == false)
                ? "Agent Finished · \(cleanTitle!)"
                : "OpenLens Reminder"
        }

        let trimmedPreview = preview.trimmingCharacters(in: .whitespacesAndNewlines)
        content.body = trimmedPreview.isEmpty
            ? "Your OpenCode session has a new update ready."
            : String(trimmedPreview.prefix(220))
        content.sound = .default
        if let sessionID {
            content.userInfo = ["sessionID": sessionID]
        }

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.5, repeats: false)
        let request = UNNotificationRequest(
            identifier: "openlens.completion-reminder.\(sessionID ?? UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        center.add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
