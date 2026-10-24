import CryptoKit
import Foundation

enum TransferEncryption {
    private static let rounds = 250_000
    private static let associatedData = Data("VPSManager server transfer v1".utf8)

    private struct Envelope: Codable {
        let version: Int
        let salt: String
        let nonce: String
        let ciphertext: String
        let tag: String
    }

    static func encrypt(_ plaintext: Data, passphrase: String) throws -> Data {
        guard !passphrase.isEmpty else {
            throw NSError(domain: "TransferEncryption", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Enter a passphrase to protect the transfer settings."
            ])
        }
        let salt = randomData(count: 16)
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData)
        let envelope = Envelope(
            version: 1,
            salt: salt.base64EncodedString(),
            nonce: sealed.nonce.withUnsafeBytes { Data($0) }.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(),
            tag: sealed.tag.base64EncodedString()
        )
        return try JSONEncoder().encode(envelope)
    }

    static func decrypt(_ encrypted: Data, passphrase: String) throws -> Data {
        let envelope = try JSONDecoder().decode(Envelope.self, from: encrypted)
        guard envelope.version == 1,
              let salt = Data(base64Encoded: envelope.salt),
              let nonceData = Data(base64Encoded: envelope.nonce),
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let ciphertext = Data(base64Encoded: envelope.ciphertext),
              let tag = Data(base64Encoded: envelope.tag) else {
            throw NSError(domain: "TransferEncryption", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "The encrypted transfer settings are invalid or unsupported."
            ])
        }
        let key = deriveKey(passphrase: passphrase, salt: salt)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: associatedData)
    }

    private static func deriveKey(passphrase: String, salt: Data) -> SymmetricKey {
        let passwordKey = SymmetricKey(data: Data(passphrase.utf8))
        var block = salt
        block.append(contentsOf: [0, 0, 0, 1])
        var previous = Data(HMAC<SHA256>.authenticationCode(for: block, using: passwordKey))
        var result = [UInt8](previous)

        for _ in 1..<rounds {
            previous = Data(HMAC<SHA256>.authenticationCode(for: previous, using: passwordKey))
            let bytes = [UInt8](previous)
            for index in result.indices { result[index] ^= bytes[index] }
        }
        return SymmetricKey(data: Data(result))
    }

    private static func randomData(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}
