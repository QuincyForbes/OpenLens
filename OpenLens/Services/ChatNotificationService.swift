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

    private nonisolated static let reminderInspectionWindowCharacters = 1_500
    private nonisolated static let reminderTrailingWindowCharacters = 500
    private nonisolated static let maximumNotificationBodyCharacters = 240

    private nonisolated static func boundedReminderInspectionSample(from text: String) -> String {
        guard text.utf8.count > reminderInspectionWindowCharacters else { return text }
        let headEnd = text.index(
            text.startIndex,
            offsetBy: reminderInspectionWindowCharacters,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        guard headEnd < text.endIndex else { return text }

        let tailStart = text.index(
            text.endIndex,
            offsetBy: -reminderTrailingWindowCharacters,
            limitedBy: headEnd
        ) ?? headEnd
        return String(text[..<headEnd]) + "\n" + String(text[tailStart...])
    }

    /// Detects natural-language requests in a chat prompt asking for a reminder or notification.
    nonisolated static func containsReminderRequest(_ text: String) -> Bool {
        let sample = boundedReminderInspectionSample(from: text)
        let lowered = sample.lowercased()
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
        let sample = boundedReminderInspectionSample(from: text)
        guard containsReminderRequest(sample) else { return nil }
        let pattern = #"\bin\s+(\d+)\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(sample.startIndex..<sample.endIndex, in: sample)
        guard let match = regex.firstMatch(in: sample, options: [], range: range),
              let amountRange = Range(match.range(at: 1), in: sample),
              let unitRange = Range(match.range(at: 2), in: sample),
              let amount = Double(sample[amountRange]),
              amount > 0 else {
            return nil
        }

        let unit = sample[unitRange].lowercased()
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
        content.body = UserMessagePresentation.boundedContextPreview(
            promptText,
            characterLimit: Self.maximumNotificationBodyCharacters
        )
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
