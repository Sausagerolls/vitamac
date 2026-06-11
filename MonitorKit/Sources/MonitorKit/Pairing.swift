import Foundation
import CryptoKit

/// Pairing turns a short human-typable code into a symmetric key. Both the
/// agent and the phone derive the identical key from the same code via HKDF,
/// and that key is used for application-layer ChaChaPoly AEAD (see
/// `SecureChannel`) over plain TCP — there is no TLS. A peer that doesn't hold
/// the code cannot produce a single openable frame, which is the pairing check.
///
/// Code length is 12 chars over a 32-symbol alphabet ≈ 60 bits of entropy, to
/// resist an offline brute force against a sniffed frame (8 chars ≈ 40 bits was
/// too weak for a key that authorizes remote process kills).
public enum MonitorPairing {
    /// Unambiguous alphabet (no I/O/0/1) for the displayed code.
    private static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let codeLength = 12

    /// A fresh pairing code shown on the Mac.
    public static func generateCode() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<codeLength).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }

    /// Normalizes user input so "abcd efgh", "ABCD-EFGH" etc. all match.
    public static func normalize(_ code: String) -> String {
        code.uppercased().filter { alphabet.contains($0) }
    }

    /// Builds the payload encoded in the Mac's pairing QR code:
    /// `monitor://pair?code=…&name=…`.
    public static func makePairingURLString(code: String, host: String) -> String {
        var comps = URLComponents()
        comps.scheme = "monitor"
        comps.host = "pair"
        comps.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "name", value: host),
        ]
        return comps.string ?? code
    }

    /// Extracts a pairing code from a scanned QR string — accepts either a
    /// `monitor://pair?code=…` URL or a bare code. Returns nil if no usable code.
    public static func extractCode(fromScanned scanned: String) -> String? {
        if let comps = URLComponents(string: scanned), comps.scheme == "monitor",
           let raw = comps.queryItems?.first(where: { $0.name == "code" })?.value {
            let n = normalize(raw)
            return n.isEmpty ? nil : n
        }
        let n = normalize(scanned)
        return n.isEmpty ? nil : n
    }

    /// Derives the 32-byte channel key from a pairing code via HKDF-SHA256.
    public static func derivePSK(fromCode code: String) -> Data {
        let normalized = normalize(code)
        let ikm = SymmetricKey(data: Data(normalized.utf8))
        let salt = Data("com.jakewatts.monitor.psk.salt.v1".utf8)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: salt,
            info: Data("monitor-tls-psk".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
