import Foundation

/// Integration point for the encrypted channel the watch requires on the iPhone (BLE) transport.
///
/// Not implemented in this repository. Provide a conformance backed by Google's official
/// open-source UKEY2 library (https://github.com/google/ukey2, Apache-2.0), acting as the
/// responder. See HANDOFF.md and research/PROTOCOL_NOTES.md (Stage 4a) for what the watch sends.
public protocol LinkEncryption: AnyObject {
    /// Handles one handshake message from the watch (the bytes of RootMessage field 17,
    /// sub-field 1) and returns the reply to send back, or nil when no reply is due.
    func handleHandshakeMessage(_ message: Data) throws -> Data?

    /// True once the handshake has finished and `seal`/`open` may be used.
    var isEstablished: Bool { get }

    /// Short code the watch shows on first pairing, for the user to compare before approving.
    var verificationCode: String? { get }

    /// Encrypts one outgoing MessagePiece payload.
    func seal(_ plaintext: Data) throws -> Data

    /// Decrypts and authenticates one incoming frame payload. Must throw on any
    /// authentication or sequence failure; callers drop the connection when it does.
    func open(_ ciphertext: Data) throws -> Data
}
