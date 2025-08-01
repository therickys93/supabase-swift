import ConcurrencyExtras
import Foundation
import HTTPTypes
import IssueReporting

#if canImport(FoundationNetworking)
  import FoundationNetworking

  extension HTTPURLResponse {
    convenience init() {
      self.init(
        url: URL(string: "http://127.0.0.1")!,
        statusCode: 200,
        httpVersion: nil,
        headerFields: nil
      )!
    }
  }
#endif

public struct RealtimeChannelConfig: Sendable {
  public var broadcast: BroadcastJoinConfig
  public var presence: PresenceJoinConfig
  public var isPrivate: Bool
}

protocol RealtimeChannelProtocol: AnyObject, Sendable {
  @MainActor var config: RealtimeChannelConfig { get }
  var topic: String { get }
  var logger: (any SupabaseLogger)? { get }

  var socket: any RealtimeClientProtocol { get }
}

public final class RealtimeChannelV2: Sendable, RealtimeChannelProtocol {
  struct MutableState {
    var clientChanges: [PostgresJoinConfig] = []
    var joinRef: String?
    var pushes: [String: PushV2] = [:]
  }

  @MainActor
  private var mutableState = MutableState()

  let topic: String

  @MainActor var config: RealtimeChannelConfig

  let logger: (any SupabaseLogger)?
  let socket: any RealtimeClientProtocol

  @MainActor var joinRef: String? { mutableState.joinRef }

  let callbackManager = CallbackManager()
  private let statusSubject = AsyncValueSubject<RealtimeChannelStatus>(.unsubscribed)

  public private(set) var status: RealtimeChannelStatus {
    get { statusSubject.value }
    set { statusSubject.yield(newValue) }
  }

  public var statusChange: AsyncStream<RealtimeChannelStatus> {
    statusSubject.values
  }

  /// Listen for connection status changes.
  /// - Parameter listener: Closure that will be called when connection status changes.
  /// - Returns: An observation handle that can be used to stop listening.
  ///
  /// - Note: Use ``statusChange`` if you prefer to use Async/Await.
  public func onStatusChange(
    _ listener: @escaping @Sendable (RealtimeChannelStatus) -> Void
  ) -> RealtimeSubscription {
    let task = statusSubject.onChange { listener($0) }
    return RealtimeSubscription { task.cancel() }
  }

  init(
    topic: String,
    config: RealtimeChannelConfig,
    socket: any RealtimeClientProtocol,
    logger: (any SupabaseLogger)?
  ) {
    self.topic = topic
    self.config = config
    self.logger = logger
    self.socket = socket
  }

  deinit {
    callbackManager.reset()
  }

  /// Subscribes to the channel.
  public func subscribeWithError() async throws {
    logger?.debug("Starting subscription to channel '\(topic)' (attempt 1/\(socket.options.maxRetryAttempts))")

    status = .subscribing

    defer {
      // If the subscription fails, we need to set the status to unsubscribed
      // to avoid the channel being stuck in a subscribing state.
      if status != .subscribed {
        status = .unsubscribed
      }
    }

    var attempts = 0

    while attempts < socket.options.maxRetryAttempts {
      attempts += 1

      do {
        logger?.debug(
          "Attempting to subscribe to channel '\(topic)' (attempt \(attempts)/\(socket.options.maxRetryAttempts))"
        )

        try await withTimeout(interval: socket.options.timeoutInterval) { [self] in
          await _subscribe()
        }

        logger?.debug("Successfully subscribed to channel '\(topic)'")
        return

      } catch is TimeoutError {
        logger?.debug(
          "Subscribe timed out for channel '\(topic)' (attempt \(attempts)/\(socket.options.maxRetryAttempts))"
        )

        if attempts < socket.options.maxRetryAttempts {
          // Add exponential backoff with jitter
          let delay = calculateRetryDelay(for: attempts)
          logger?.debug(
            "Retrying subscription to channel '\(topic)' in \(String(format: "%.2f", delay)) seconds..."
          )

          do {
            try await _clock.sleep(for: delay)
          } catch {
            // If sleep is cancelled, break out of retry loop
            logger?.debug("Subscription retry cancelled for channel '\(topic)'")
            throw CancellationError()
          }
        } else {
          logger?.error(
            "Failed to subscribe to channel '\(topic)' after \(socket.options.maxRetryAttempts) attempts due to timeout"
          )
        }
      } catch is CancellationError {
        logger?.debug("Subscription retry cancelled for channel '\(topic)'")
        throw CancellationError()
      } catch {
        preconditionFailure(
          "The only possible error here is TimeoutError or CancellationError, this should never happen."
        )
      }
    }

    logger?.error("Subscription to channel '\(topic)' failed after \(attempts) attempts")
    throw RealtimeError.maxRetryAttemptsReached
  }

  /// Subscribes to the channel.
  @available(*, deprecated, message: "Use `subscribeWithError` instead")
  @MainActor
  public func subscribe() async {
    try? await subscribeWithError()
  }

  /// Calculates retry delay with exponential backoff and jitter
  private func calculateRetryDelay(for attempt: Int) -> TimeInterval {
    let baseDelay: TimeInterval = 1.0
    let maxDelay: TimeInterval = 30.0
    let backoffMultiplier: Double = 2.0

    let exponentialDelay = baseDelay * pow(backoffMultiplier, Double(attempt - 1))
    let cappedDelay = min(exponentialDelay, maxDelay)

    // Add jitter (±25% random variation) to prevent thundering herd
    let jitterRange = cappedDelay * 0.25
    let jitter = Double.random(in: -jitterRange...jitterRange)

    return max(0.1, cappedDelay + jitter)
  }

  /// Subscribes to the channel
  @MainActor
  private func _subscribe() async {
    if socket.status != .connected {
      if socket.options.connectOnSubscribe != true {
        reportIssue(
          "You can't subscribe to a channel while the realtime client is not connected. Did you forget to call `realtime.connect()`?"
        )
        return
      }
      await socket.connect()
    }

    logger?.debug("Subscribing to channel \(topic)")

    config.presence.enabled = callbackManager.callbacks.contains(where: { $0.isPresence })

    let joinConfig = RealtimeJoinConfig(
      broadcast: config.broadcast,
      presence: config.presence,
      postgresChanges: mutableState.clientChanges,
      isPrivate: config.isPrivate
    )

    let payload = RealtimeJoinPayload(
      config: joinConfig,
      accessToken: await socket._getAccessToken(),
      version: socket.options.headers[.xClientInfo]
    )

    let joinRef = socket.makeRef()
    mutableState.joinRef = joinRef

    logger?.debug("Subscribing to channel with body: \(joinConfig)")

    await push(
      ChannelEvent.join,
      ref: joinRef,
      payload: try! JSONObject(payload)
    )

    _ = await statusChange.first { @Sendable in $0 == .subscribed }
  }

  public func unsubscribe() async {
    status = .unsubscribing
    logger?.debug("Unsubscribing from channel \(topic)")

    await push(ChannelEvent.leave)
  }

  @available(
    *,
    deprecated,
    message:
      "manually updating auth token per channel is not recommended, please use `setAuth` in RealtimeClient instead."
  )
  public func updateAuth(jwt: String?) async {
    logger?.debug("Updating auth token for channel \(topic)")
    await push(
      ChannelEvent.accessToken,
      payload: ["access_token": jwt.map { .string($0) } ?? .null]
    )
  }

  /// Send a broadcast message with `event` and a `Codable` payload.
  /// - Parameters:
  ///   - event: Broadcast message event.
  ///   - message: Message payload.
  public func broadcast(event: String, message: some Codable) async throws {
    try await broadcast(event: event, message: JSONObject(message))
  }

  /// Send a broadcast message with `event` and a raw `JSON` payload.
  /// - Parameters:
  ///   - event: Broadcast message event.
  ///   - message: Message payload.
  @MainActor
  public func broadcast(event: String, message: JSONObject) async {
    if status != .subscribed {
      var headers: HTTPFields = [.contentType: "application/json"]
      if let apiKey = socket.options.apikey {
        headers[.apiKey] = apiKey
      }
      if let accessToken = await socket._getAccessToken() {
        headers[.authorization] = "Bearer \(accessToken)"
      }

      struct BroadcastMessagePayload: Encodable {
        let messages: [Message]

        struct Message: Encodable {
          let topic: String
          let event: String
          let payload: JSONObject
          let `private`: Bool
        }
      }

      let task = Task { [headers] in
        _ = try? await socket.http.send(
          HTTPRequest(
            url: socket.broadcastURL,
            method: .post,
            headers: headers,
            body: JSONEncoder().encode(
              BroadcastMessagePayload(
                messages: [
                  BroadcastMessagePayload.Message(
                    topic: topic,
                    event: event,
                    payload: message,
                    private: config.isPrivate
                  )
                ]
              )
            )
          )
        )
      }

      if config.broadcast.acknowledgeBroadcasts {
        try? await withTimeout(interval: socket.options.timeoutInterval) {
          await task.value
        }
      }
    } else {
      await push(
        ChannelEvent.broadcast,
        payload: [
          "type": "broadcast",
          "event": .string(event),
          "payload": .object(message),
        ]
      )
    }
  }

  /// Tracks the given state in the channel.
  /// - Parameter state: The state to be tracked, conforming to `Codable`.
  /// - Throws: An error if the tracking fails.
  public func track(_ state: some Codable) async throws {
    try await track(state: JSONObject(state))
  }

  /// Tracks the given state in the channel.
  /// - Parameter state: The state to be tracked as a `JSONObject`.
  public func track(state: JSONObject) async {
    if status != .subscribed {
      reportIssue(
        "You can only track your presence after subscribing to the channel. Did you forget to call `channel.subscribe()`?"
      )
    }

    await push(
      ChannelEvent.presence,
      payload: [
        "type": "presence",
        "event": "track",
        "payload": .object(state),
      ]
    )
  }

  /// Stops tracking the current state in the channel.
  public func untrack() async {
    await push(
      ChannelEvent.presence,
      payload: [
        "type": "presence",
        "event": "untrack",
      ]
    )
  }

  func onMessage(_ message: RealtimeMessageV2) async {
    do {
      guard let eventType = message._eventType else {
        logger?.debug("Received message without event type: \(message)")
        return
      }

      switch eventType {
      case .tokenExpired:
        // deprecated type
        break

      case .system:
        if message.status == .ok {
          logger?.debug("Subscribed to channel \(message.topic)")
          status = .subscribed
        } else {
          logger?.debug(
            "Failed to subscribe to channel \(message.topic): \(message.payload)"
          )
        }

        callbackManager.triggerSystem(message: message)

      case .reply:
        guard
          let ref = message.ref,
          let status = message.payload["status"]?.stringValue
        else {
          throw RealtimeError("Received a reply with unexpected payload: \(message)")
        }

        await didReceiveReply(ref: ref, status: status)

        if message.payload["response"]?.objectValue?.keys
          .contains(ChannelEvent.postgresChanges) == true
        {
          let serverPostgresChanges = try message.payload["response"]?
            .objectValue?["postgres_changes"]?
            .decode(as: [PostgresJoinConfig].self)

          callbackManager.setServerChanges(changes: serverPostgresChanges ?? [])

          if self.status != .subscribed {
            self.status = .subscribed
            logger?.debug("Subscribed to channel \(message.topic)")
          }
        }

      case .postgresChanges:
        guard let data = message.payload["data"] else {
          logger?.debug("Expected \"data\" key in message payload.")
          return
        }

        let ids = message.payload["ids"]?.arrayValue?.compactMap(\.intValue) ?? []

        let postgresActions = try data.decode(as: PostgresActionData.self)

        let action: AnyAction
        switch postgresActions.type {
        case "UPDATE":
          action = .update(
            UpdateAction(
              columns: postgresActions.columns,
              commitTimestamp: postgresActions.commitTimestamp,
              record: postgresActions.record ?? [:],
              oldRecord: postgresActions.oldRecord ?? [:],
              rawMessage: message
            )
          )

        case "DELETE":
          action = .delete(
            DeleteAction(
              columns: postgresActions.columns,
              commitTimestamp: postgresActions.commitTimestamp,
              oldRecord: postgresActions.oldRecord ?? [:],
              rawMessage: message
            )
          )

        case "INSERT":
          action = .insert(
            InsertAction(
              columns: postgresActions.columns,
              commitTimestamp: postgresActions.commitTimestamp,
              record: postgresActions.record ?? [:],
              rawMessage: message
            )
          )

        default:
          throw RealtimeError("Unknown event type: \(postgresActions.type)")
        }

        callbackManager.triggerPostgresChanges(ids: ids, data: action)

      case .broadcast:
        let payload = message.payload

        guard let event = payload["event"]?.stringValue else {
          throw RealtimeError("Expected 'event' key in 'payload' for broadcast event.")
        }

        callbackManager.triggerBroadcast(event: event, json: payload)

      case .close:
        socket._remove(self)
        logger?.debug("Unsubscribed from channel \(message.topic)")
        status = .unsubscribed

      case .error:
        logger?.error(
          "Received an error in channel \(message.topic). That could be as a result of an invalid access token"
        )

      case .presenceDiff:
        let joins = try message.payload["joins"]?.decode(as: [String: PresenceV2].self) ?? [:]
        let leaves = try message.payload["leaves"]?.decode(as: [String: PresenceV2].self) ?? [:]
        callbackManager.triggerPresenceDiffs(joins: joins, leaves: leaves, rawMessage: message)

      case .presenceState:
        let joins = try message.payload.decode(as: [String: PresenceV2].self)
        callbackManager.triggerPresenceDiffs(joins: joins, leaves: [:], rawMessage: message)
      }
    } catch {
      logger?.debug("Failed: \(error)")
    }
  }

  /// Listen for clients joining / leaving the channel using presences.
  public func onPresenceChange(
    _ callback: @escaping @Sendable (any PresenceAction) -> Void
  ) -> RealtimeSubscription {
    if status == .subscribed {
      logger?.debug(
        "Resubscribe to \(self.topic) due to change in presence callback on joined channel."
      )
      Task {
        await unsubscribe()
        await subscribe()
      }
    }

    let id = callbackManager.addPresenceCallback(callback: callback)

    return RealtimeSubscription { [weak callbackManager, logger] in
      logger?.debug("Removing presence callback with id: \(id)")
      callbackManager?.removeCallback(id: id)
    }
  }

  /// Listen for postgres changes in a channel.
  public func onPostgresChange(
    _: AnyAction.Type,
    schema: String = "public",
    table: String? = nil,
    filter: String? = nil,
    callback: @escaping @Sendable (AnyAction) -> Void
  ) -> RealtimeSubscription {
    _onPostgresChange(
      event: .all,
      schema: schema,
      table: table,
      filter: filter
    ) {
      callback($0)
    }
  }

  /// Listen for postgres changes in a channel.
  public func onPostgresChange(
    _: InsertAction.Type,
    schema: String = "public",
    table: String? = nil,
    filter: String? = nil,
    callback: @escaping @Sendable (InsertAction) -> Void
  ) -> RealtimeSubscription {
    _onPostgresChange(
      event: .insert,
      schema: schema,
      table: table,
      filter: filter
    ) {
      guard case let .insert(action) = $0 else { return }
      callback(action)
    }
  }

  /// Listen for postgres changes in a channel.
  public func onPostgresChange(
    _: UpdateAction.Type,
    schema: String = "public",
    table: String? = nil,
    filter: String? = nil,
    callback: @escaping @Sendable (UpdateAction) -> Void
  ) -> RealtimeSubscription {
    _onPostgresChange(
      event: .update,
      schema: schema,
      table: table,
      filter: filter
    ) {
      guard case let .update(action) = $0 else { return }
      callback(action)
    }
  }

  /// Listen for postgres changes in a channel.
  public func onPostgresChange(
    _: DeleteAction.Type,
    schema: String = "public",
    table: String? = nil,
    filter: String? = nil,
    callback: @escaping @Sendable (DeleteAction) -> Void
  ) -> RealtimeSubscription {
    _onPostgresChange(
      event: .delete,
      schema: schema,
      table: table,
      filter: filter
    ) {
      guard case let .delete(action) = $0 else { return }
      callback(action)
    }
  }

  func _onPostgresChange(
    event: PostgresChangeEvent,
    schema: String,
    table: String?,
    filter: String?,
    callback: @escaping @Sendable (AnyAction) -> Void
  ) -> RealtimeSubscription {
    guard status != .subscribed else {
      reportIssue(
        "You cannot call postgresChange after joining the channel, this won't work as expected."
      )
      return RealtimeSubscription {}
    }

    let config = PostgresJoinConfig(
      event: event,
      schema: schema,
      table: table,
      filter: filter
    )

    Task { @MainActor in
      mutableState.clientChanges.append(config)
    }

    let id = callbackManager.addPostgresCallback(filter: config, callback: callback)
    return RealtimeSubscription { [weak callbackManager, logger] in
      logger?.debug("Removing postgres callback with id: \(id)")
      callbackManager?.removeCallback(id: id)
    }
  }

  /// Listen for broadcast messages sent by other clients within the same channel under a specific `event`.
  public func onBroadcast(
    event: String,
    callback: @escaping @Sendable (JSONObject) -> Void
  ) -> RealtimeSubscription {
    let id = callbackManager.addBroadcastCallback(event: event, callback: callback)
    return RealtimeSubscription { [weak callbackManager, logger] in
      logger?.debug("Removing broadcast callback with id: \(id)")
      callbackManager?.removeCallback(id: id)
    }
  }

  /// Listen for `system` event.
  public func onSystem(
    callback: @escaping @Sendable (RealtimeMessageV2) -> Void
  ) -> RealtimeSubscription {
    let id = callbackManager.addSystemCallback(callback: callback)
    return RealtimeSubscription { [weak callbackManager, logger] in
      logger?.debug("Removing system callback with id: \(id)")
      callbackManager?.removeCallback(id: id)
    }
  }

  /// Listen for `system` event.
  public func onSystem(
    callback: @escaping @Sendable () -> Void
  ) -> RealtimeSubscription {
    self.onSystem { _ in callback() }
  }

  @MainActor
  @discardableResult
  func push(_ event: String, ref: String? = nil, payload: JSONObject = [:]) async -> PushStatus {
    let message = RealtimeMessageV2(
      joinRef: joinRef,
      ref: ref ?? socket.makeRef(),
      topic: self.topic,
      event: event,
      payload: payload
    )

    let push = PushV2(channel: self, message: message)
    if let ref = message.ref {
      mutableState.pushes[ref] = push
    }

    return await push.send()
  }

  @MainActor
  private func didReceiveReply(ref: String, status: String) {
    let push = mutableState.pushes.removeValue(forKey: ref)
    push?.didReceive(status: PushStatus(rawValue: status) ?? .ok)
  }
}
