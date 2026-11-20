import CryptoKit
import Foundation
import IOKit

/// Approval without club.json (docs/protocol.md): LJ Link knows an approved Mac by a pseudonym that is different for
/// every LJ Link. It is derived from the Mac's hardware UUID, so nothing has to be stored on the DJ's Mac and the UUID
/// itself never leaves it.
public enum Pairing {
    /// The pseudonym of this Mac for the LJ Link with Bonjour TXT `booth=<id>`: the first 32 hex digits of
    /// HMAC-SHA256(key: hardware UUID, message: "ljl-pair:" + booth).
    public static func device(booth: String, secret: String? = nil) -> String? {
        guard !booth.isEmpty, let s = secret ?? hardwareUUID, !s.isEmpty else { return nil }
        let mac = HMAC<SHA256>.authenticationCode(for: Data("ljl-pair:\(booth)".utf8), using: SymmetricKey(data: Data(s.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// IOPlatformUUID of this Mac; read once.
    public static let hardwareUUID: String? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }()
}
