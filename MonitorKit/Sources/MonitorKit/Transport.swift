import Foundation
import Network
import CryptoKit

/// Transport parameters shared by the agent (listener) and client. Plain TCP;
/// confidentiality/auth is provided at the application layer by `SecureChannel`.
public enum MonitorTransport {
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true   // allow AWDL/peer-to-peer for Bonjour
        return params
    }
}

/// Transport-only client: connects to an endpoint, sends `ClientMessage`s
/// sealed under the pairing key, and surfaces decoded `ServerMessage`s as an
/// async stream. UI state lives in the iOS layer.
public final class MonitorClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case setup, connecting, ready, failed(String), cancelled
    }

    private let connection: NWConnection
    private let channel: SecureChannel
    private let queue = DispatchQueue(label: "com.jakewatts.monitor.client")
    private var buffer = Data()
    private let continuation: AsyncStream<ServerMessage>.Continuation

    public let messages: AsyncStream<ServerMessage>
    public var onState: (@Sendable (State) -> Void)?
    public var onWaiting: (@Sendable (String) -> Void)?

    public init(endpoint: NWEndpoint, channel: SecureChannel) {
        self.channel = channel
        connection = NWConnection(to: endpoint, using: MonitorTransport.parameters())
        var cont: AsyncStream<ServerMessage>.Continuation!
        messages = AsyncStream(bufferingPolicy: .unbounded) { cont = $0 }
        continuation = cont
    }

    public convenience init(endpoint: NWEndpoint, code: String) {
        self.init(endpoint: endpoint, channel: SecureChannel(code: code))
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .setup: self.onState?(.setup)
            case .preparing: self.onState?(.connecting)
            case .waiting(let error):
                self.onState?(.connecting)
                self.onWaiting?("\(error)")
            case .ready:
                self.onState?(.ready)
                self.receiveLoop()
            case .failed(let error):
                self.onState?(.failed(error.localizedDescription))
                self.continuation.finish()
            case .cancelled:
                self.onState?(.cancelled)
                self.continuation.finish()
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ message: ClientMessage) {
        guard let data = try? channel.seal(message) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                do {
                    while let payload = try MonitorFraming.nextPayload(from: &self.buffer) {
                        if let msg = try? self.channel.open(ServerMessage.self, from: payload) {
                            self.continuation.yield(msg)
                        }
                    }
                } catch {
                    // Oversized/garbage length prefix — drop the connection.
                    self.connection.cancel()
                    self.continuation.finish()
                    return
                }
            }
            if isComplete || error != nil {
                self.continuation.finish()
                return
            }
            self.receiveLoop()
        }
    }
}
