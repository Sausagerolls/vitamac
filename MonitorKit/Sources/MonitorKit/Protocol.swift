import Foundation

/// Wire protocol version. Bumped on any breaking change to message shapes.
/// v2: added session nonce + per-process start time for replay/PID-reuse-safe kills.
/// v3: added a stable per-device ID to `hello` for the paired-devices list + revoke.
/// v4: added on-demand process app-icon fetch (requestIcons / icons).
/// v5: added GPU stats to SystemSample + Mac power controls (control/controlResult).
public let kMonitorProtocolVersion = 5

/// Bonjour service type the agent advertises and the iOS app browses for.
public let kMonitorBonjourServiceType = "_monitor._tcp"

/// Hard cap on a single framed message (sealed JSON). Comfortably above the
/// largest process snapshot; bounds attacker-controlled buffer growth.
public let kMonitorMaxFrameLength = 16 * 1024 * 1024  // 16 MiB

/// Messages sent from the iOS client to the macOS agent.
public enum ClientMessage: Codable, Sendable {
    /// First message after connecting. `deviceID` is a stable per-install ID used
    /// for the agent's paired-devices list + revocation. `pairingCode` is
    /// informational (auth is the AEAD channel).
    case hello(clientName: String, deviceID: String, protocolVersion: Int, pairingCode: String?)
    case requestSnapshot
    /// `startTime` and `sessionNonce` make the kill replay-safe and immune to
    /// PID reuse: the server rejects it unless the nonce matches this session
    /// and the live process still has the same start time the client saw.
    case kill(pid: Int32, signal: Int32, startTime: UInt64, sessionNonce: UInt64)
    /// Lazily fetch app icons for these executable paths (only what's on screen).
    case requestIcons(paths: [String])
    /// A Mac power/display action; carries the session nonce like kill so a
    /// captured control frame can't be replayed from another session.
    case control(action: MacControlAction, sessionNonce: UInt64)
    case ping
}

/// One process's app icon: PNG bytes keyed by executable path (the cache key).
public struct IconEntry: Codable, Sendable {
    public let path: String
    public let png: Data
    public init(path: String, png: Data) { self.path = path; self.png = png }
}

/// Messages sent from the macOS agent to the iOS client.
public enum ServerMessage: Codable, Sendable {
    /// `sessionNonce` is freshly random per connection; the client echoes it on
    /// kills so a captured kill frame from another session is rejected.
    case helloAck(serverName: String, protocolVersion: Int, paired: Bool, sessionNonce: UInt64)
    case pairingRequired
    case pairingFailed(reason: String)
    case system(SystemSample)
    case snapshot([ProcessSample])
    case killResult(pid: Int32, success: Bool, message: String)
    case icons([IconEntry])
    case controlResult(action: MacControlAction, success: Bool, message: String)
    case error(String)
    case pong
}

public enum MonitorSignal: Int32, Codable, Sendable, CaseIterable {
    case term = 15  // SIGTERM – graceful
    case kill = 9   // SIGKILL – force

    public var label: String { self == .term ? "Quit" : "Force Kill" }
}

/// System power/display actions the agent can perform for the logged-in user.
public enum MacControlAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case restart, shutDown, sleepSystem, sleepDisplay

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .restart: return "Restart"
        case .shutDown: return "Shut Down"
        case .sleepSystem: return "Sleep"
        case .sleepDisplay: return "Turn Off Display"
        }
    }
    public var systemImage: String {
        switch self {
        case .restart: return "arrow.clockwise.circle"
        case .shutDown: return "power"
        case .sleepSystem: return "moon"
        case .sleepDisplay: return "display"
        }
    }
    /// Destructive actions that should get an extra confirmation.
    public var isDestructive: Bool { self == .restart || self == .shutDown }
}

// MARK: - Length-prefixed JSON framing

/// Encodes/decodes messages as a 4-byte big-endian length prefix followed by
/// JSON. Both ends are Swift, so associated-value enum coding is symmetric.
public enum MonitorFraming {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// Wraps an arbitrary payload (already-encrypted bytes, JSON, etc.) with a
    /// 4-byte big-endian length prefix.
    public static func frameData(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }

    public static func frame<T: Encodable>(_ value: T) throws -> Data {
        frameData(try encoder.encode(value))
    }

    /// Pulls one complete message out of `buffer` if present, removing its bytes.
    /// Returns nil when more bytes are needed. Throws `frameTooLarge` if the
    /// length prefix exceeds `kMonitorMaxFrameLength`, so the caller can drop a
    /// peer trying to make us buffer gigabytes (it never assembles the frame, so
    /// the normal decrypt-or-reject path would never fire).
    public static func nextPayload(from buffer: inout Data) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        if Int(length) > kMonitorMaxFrameLength {
            throw MonitorFramingError.frameTooLarge(Int(length))
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return payload
    }
}

public enum MonitorFramingError: Error, Equatable {
    case frameTooLarge(Int)
}
