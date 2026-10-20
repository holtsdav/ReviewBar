import Foundation
import UIKit
import UserNotifications

@MainActor
final class PushRegistrationCenter {
    static let shared = PushRegistrationCenter()
    private var continuations: [UUID: CheckedContinuation<Data, Error>] = [:]

    func requestDeviceToken() async throws -> Data {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        guard granted else {
            throw AppError(kind: .insufficientPermission, message: "Allow notifications in iOS Settings to enable real-time status updates.")
        }
        return try await registerForDeviceToken()
    }

    /// APNs recommends registering on every launch because the token can
    /// change. This does not prompt; permission was obtained during opt-in.
    func registerForDeviceToken() async throws -> Data {
        let identifier = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                continuations[identifier] = continuation
                if Task.isCancelled {
                    cancel(identifier)
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    self?.timeout(identifier)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(identifier) }
        }
    }

    func didRegister(deviceToken: Data) {
        let pending = Array(continuations.values)
        continuations = [:]
        pending.forEach { $0.resume(returning: deviceToken) }
    }

    func didFail(error: Error) {
        let pending = Array(continuations.values)
        continuations = [:]
        let mapped = AppError(
            kind: .other,
            message: "This device couldn't register with Apple Push Notification service. \(error.localizedDescription)"
        )
        pending.forEach { $0.resume(throwing: mapped) }
    }

    private func timeout(_ identifier: UUID) {
        guard let continuation = continuations.removeValue(forKey: identifier) else { return }
        continuation.resume(throwing: AppError(
            kind: .other,
            message: "Apple Push Notification registration timed out. Check your connection and try again."
        ))
    }

    private func cancel(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)?.resume(throwing: CancellationError())
    }
}

final class ReviewBarAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ReviewBarStartup.current.configureNotifications {
            UNUserNotificationCenter.current().delegate = self
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard !ReviewBarStartup.current.isServiceFreeTestHost else { return }
        Task { @MainActor in PushRegistrationCenter.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        guard !ReviewBarStartup.current.isServiceFreeTestHost else { return }
        Task { @MainActor in PushRegistrationCenter.shared.didFail(error: error) }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

extension Data {
    var lowercaseHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
