import Foundation
import CryptoKit

/// Application-layer secure channel. Each message is JSON-encoded then sealed
/// with ChaChaPoly (AEAD) under a key derived from the pairing code, and sent
/// as a length-prefixed frame. This gives confidentiality + integrity +
/// authentication without relying on TLS-PSK cipher negotiation.
///
/// Pairing is enforced cryptographically: a peer that doesn't hold the key
/// produces frames that `open` rejects, so a wrong pairing code can never
/// exchange a single valid message.
///
/// Scope note (v1): no forward secrecy and no cross-reconnect replay
/// protection. Acceptable for a trusted-LAN tool; revisit if exposed beyond LAN.
public struct SecureChannel: Sendable {
    private let key: SymmetricKey

    public init(key: SymmetricKey) { self.key = key }

    public init(code: String) {
        self.key = SymmetricKey(data: MonitorPairing.derivePSK(fromCode: code))
    }

    /// JSON-encode → seal → length-prefix.
    public func seal<T: Encodable>(_ value: T) throws -> Data {
        let json = try MonitorFraming.encoder.encode(value)
        let box = try ChaChaPoly.seal(json, using: key)
        return MonitorFraming.frameData(box.combined)
    }

    /// Open a sealed payload (the bytes between length prefixes) → decode.
    /// Throws if the payload wasn't sealed with the matching key.
    public func open<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        let box = try ChaChaPoly.SealedBox(combined: payload)
        let json = try ChaChaPoly.open(box, using: key)
        return try MonitorFraming.decoder.decode(type, from: json)
    }
}
