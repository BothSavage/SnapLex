import CryptoKit
import Foundation

// Check the feed against the public key embedded in the app, not the key used
// by the release machine. A wrong private key must stop publishing.
let publicKey = "mVBZlQtFsQAnDQeK67N1iHhLqFESazmbYuox/6yOrPY="
guard CommandLine.arguments.count == 2,
      let keyData = Data(base64Encoded: publicKey),
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
      let text = String(data: data, encoding: .utf8) else {
    fputs("Unable to read the update feed.\n", stderr)
    exit(1)
}
let pattern = #"<!-- sparkle-signatures:\s*edSignature: ([A-Za-z0-9+/=]+)\s*length: ([0-9]+)\s*-->\s*$"#
let regex = try NSRegularExpression(pattern: pattern)
let range = NSRange(text.startIndex..., in: text)
guard let match = regex.firstMatch(in: text, range: range),
      let signatureRange = Range(match.range(at: 1), in: text),
      let lengthRange = Range(match.range(at: 2), in: text),
      let signature = Data(base64Encoded: String(text[signatureRange])),
      let length = Int(text[lengthRange]), length >= 0, length <= data.count,
      let suffix = String(data: data.dropFirst(length), encoding: .utf8),
      suffix.hasPrefix("<!-- sparkle-signatures:"),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
      key.isValidSignature(signature, for: data.prefix(length)) else {
    fputs("Update feed signature does not match the public key embedded in SnapLex.\n", stderr)
    exit(1)
}
print("Update feed signature verified.")
