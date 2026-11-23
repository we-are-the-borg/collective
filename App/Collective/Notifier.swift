import AppKit
import CollectiveKit
import os
import UserNotifications

/// Posts and withdraws the macOS notifications the kit's `NotificationPlanner`
/// asks for; what to notify of is decided there, not here.
///
/// Permission is asked for only once there is something to post, so a user
/// who never gets a notification is never asked. After the user decided, the
/// system answers by itself and nothing is asked again; denied, wishes are dropped.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// A click on one of the app's notifications, with the session it was
    /// posted for; nil for one that names none, e.g. from an older build.
    var onOpen: (SessionKey?) -> Void = { _ in }

    private let center = UNUserNotificationCenter.current()
    /// Wishes not handed to the center yet, in order.
    private var queue: [NotificationWish] = []
    private var isPosting = false
    /// Ids handed to the center but not yet confirmed; a withdrawal meanwhile
    /// lands in `withdrawnInFlight`, so it is removed once it is there.
    private var inFlight: Set<String> = []
    private var withdrawnInFlight: Set<String> = []

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Collective", category: "Notifications")

    /// Before anything is posted and before a click can arrive. The planner
    /// knows nothing of the previous run's notifications, so they go: none of
    /// them could ever be withdrawn when what it reported is over.
    func start() {
        center.delegate = self
        center.removeAllDeliveredNotifications()
    }

    func post(_ wishes: [NotificationWish]) {
        guard !wishes.isEmpty else { return }
        queue.append(contentsOf: wishes)
        guard !isPosting else { return }
        isPosting = true
        Task { await postQueued() }
    }

    /// Also cancels a wish not shown yet, so a withdrawal right after a post wins.
    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let withdrawn = Set(ids)
        queue.removeAll { withdrawn.contains($0.id) }
        withdrawnInFlight.formUnion(withdrawn.intersection(inFlight))
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// The user turned the app's notifications off in System Settings; not
    /// asked yet counts as on, since the first notification will ask.
    func isTurnedOff() async -> Bool {
        await center.notificationSettings().authorizationStatus == .denied
    }

    /// One at a time off the queue, so a withdrawal meanwhile still finds the rest there.
    private func postQueued() async {
        if await isAllowed() {
            while !queue.isEmpty { await add(queue.removeFirst()) }
        } else {
            queue.removeAll()
        }
        isPosting = false
    }

    /// Asks only while the user has not decided; the system shows its prompt once.
    private func isAllowed() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.log.error("Could not ask for permission to notify: \(String(describing: error), privacy: .public)")
                return false
            }
        case .denied:
            return false
        default:
            return true
        }
    }

    private func add(_ wish: NotificationWish) async {
        let content = UNMutableNotificationContent()
        content.title = wish.title
        content.subtitle = wish.subtitle
        content.body = wish.body
        content.threadIdentifier = wish.threadID
        content.userInfo = SessionKey.notificationUserInfo(for: wish.session)
        if wish.playsSound { content.sound = .default }
        inFlight.insert(wish.id)
        do {
            try await center.add(UNNotificationRequest(identifier: wish.id, content: content, trigger: nil))
        } catch {
            Self.log.error("Could not post a notification: \(String(describing: error), privacy: .public)")
        }
        inFlight.remove(wish.id)
        if withdrawnInFlight.remove(wish.id) != nil {
            center.removeDeliveredNotifications(withIdentifiers: [wish.id])
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// The app is a menu bar app, yet active while the popover or a window of
    /// it is open; without this the system would not show the banner then.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notification.request.content.sound == nil ? [.banner, .list] : [.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            let key = SessionKey(notificationUserInfo: response.notification.request.content.userInfo)
            Task { @MainActor in self.onOpen(key) }
        }
        completionHandler()
    }
}
