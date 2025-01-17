import AnalyticsClient
import API
import ComposableArchitecture
import FirebaseAuthClient
import FirebaseCoreClient
import FirebaseMessagingClient
import UIApplicationClient
import UIKit
import UserNotificationClient

@Reducer
public struct AppDelegateLogic {
  public struct State: Equatable {}
  public enum Action {
    case didFinishLaunching(UIApplication, [UIApplication.LaunchOptionsKey: Any]?)
    case open(UIApplication, URL, [UIApplication.OpenURLOptionsKey: Any])
    case didReceiveRemoteNotification([AnyHashable: Any])
    case didRegisterForRemoteNotifications(TaskResult<Data>)
    case configurationForConnecting(UIApplicationShortcutItem?)
    case userNotifications(UserNotificationClient.DelegateEvent)
    case messaging(FirebaseMessagingClient.DelegateAction)
    case createFirebaseRegistrationTokenResponse(Result<API.CreateFirebaseRegistrationTokenMutation.Data, Error>)
    case delegate(Delegate)

    public enum Delegate: Equatable {
      case didFinishLaunching
    }

    public static func == (lhs: AppDelegateLogic.Action, rhs: AppDelegateLogic.Action) -> Bool {
      switch (lhs, rhs) {
      case (.didReceiveRemoteNotification, .didReceiveRemoteNotification):
        return false
      default:
        return lhs == rhs
      }
    }
  }

  @Dependency(\.analytics) var analytics
  @Dependency(\.firebaseCore) var firebaseCore
  @Dependency(\.firebaseAuth) var firebaseAuth
  @Dependency(\.userNotifications) var userNotifications
  @Dependency(\.firebaseMessaging) var firebaseMessaging
  @Dependency(\.api.createFirebaseRegistrationToken) var createFirebaseRegistrationToken
  @Dependency(\.application.registerForRemoteNotifications) var registerForRemoteNotifications

  public func reduce(into state: inout State, action: Action) -> Effect<Action> {
    switch action {
    case .didFinishLaunching:
      firebaseCore.configure()
      return .run { @MainActor send in
        await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask {
            for await event in userNotifications.delegate() {
              await send(.userNotifications(event))
            }
          }
          group.addTask {
            for await event in firebaseMessaging.delegate() {
              await send(.messaging(event))
            }
          }
          group.addTask {
            await send(.delegate(.didFinishLaunching))
          }
        }
      }

    case let .didReceiveRemoteNotification(userInfo):
      guard let badge = userInfo["badge"] as? String else { return .none }
      guard let badgeCount = Int(badge) else { return .none }
      return .run { _ in
        try? await userNotifications.setBadgeCount(badgeCount)
      }
    case .didRegisterForRemoteNotifications(.failure):
      return .none

    case let .didRegisterForRemoteNotifications(.success(tokenData)):
      return .run { send in
        #if DEBUG
          firebaseAuth.setAPNSToken(tokenData, .sandbox)
        #else
          firebaseAuth.setAPNSToken(tokenData, .prod)
        #endif
        firebaseMessaging.setAPNSToken(tokenData)
        await createFirebaseRegistrationTokenRequest(send: send)
      }

    case let .userNotifications(.willPresentNotification(notification, completionHandler)):
      return .run { _ in
        _ = firebaseMessaging.appDidReceiveMessage(notification.request)
        completionHandler([.list, .sound, .badge, .banner])
      }

    case let .userNotifications(.didReceiveResponse(response, completionHandler)):
      return .run { _ in
        _ = firebaseMessaging.appDidReceiveMessage(response.notification.request)
        completionHandler()
      }

    case .messaging(.didReceiveRegistrationToken):
      return .run { send in
        await createFirebaseRegistrationTokenRequest(send: send)
      }

    default:
      return .none
    }
  }

  func createFirebaseRegistrationTokenRequest(send: Send<Action>) async {
    do {
      let token = try await firebaseMessaging.token()
      let input = API.CreateFirebaseRegistrationTokenInput(token: token)
      await send(.createFirebaseRegistrationTokenResponse(Result {
        try await createFirebaseRegistrationToken(input)
      }))
    } catch {
      print("createFirebaseRegistrationTokenRequest: \(error)")
    }
  }
}
