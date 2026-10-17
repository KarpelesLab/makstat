import Foundation
import UserNotifications

enum Notifier {
    private static var authorized = false
    private static var requested = false

    static func requestAuthorization() {
        guard !requested else { return }
        requested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            authorized = granted
            if let error { NSLog("notification authorization: \(error)") }
        }
    }

    static func send(title: String, body: String) {
        requestAuthorization()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("notification: \(error)") }
        }
    }
}
