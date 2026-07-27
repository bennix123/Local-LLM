// MerchantNormalizerTests — pins the Categorization-Engine-v2 "Merchant
// Normalization" + "Display Names" specification: every raw descriptor in the
// spec table must resolve to the documented clean name, plus generic clean-up
// for merchants that aren't in the alias list.
import XCTest
@testable import PennyTxnStore

final class MerchantNormalizerTests: XCTestCase {

    /// The exact spec table (raw → normalized display name).
    func testSpecNormalizationTable() {
        let table: [(String, String)] = [
            ("TFL TRAVEL CHARGE       TFL.GOV.UK/CP", "TFL"),
            ("DOJO*THE CRAFT BEER CO  LONDON", "The Craft Beer Co"),
            ("DOJO*BEEHIVE            LONDON", "Beehive"),
            ("APPLE.COM/BILL          HOLLYHILL", "Apple"),
            ("AMAZON PRIME*227DM1GO5  AMZN.CO.UK/PM", "Amazon Prime"),
            ("3500728 Kings Arms Oxfo Westminster", "Kings Arms"),
            ("TEYA*LITLI DUBLINER FRA REYKJAVIK", "Litli Dubliner"),
            ("CARE DENTAL PLATINUM    LONDON", "Care Dental Platinum"),
            ("CAREDENTALPLATINUM.COM  CRAWLEY", "Care Dental Platinum"),
            ("FOREST                  LONDON", "Forest"),
            ("LIME*PASS DXIZ          LONDON", "Lime"),
            ("LIME*RIDE DXIZ          LONDON", "Lime"),
            ("PRET A MANGER           London", "Pret A Manger"),
            ("TST-THE KATI ROLL POLA  LONDON", "The Kati Roll Company"),
            ("TAMESIS DOCK            London", "Tamesis Dock"),
            ("LOKAL                   HOUNSLOW", "Lokal"),
        ]
        for (raw, want) in table {
            XCTAssertEqual(MerchantNormalizer.normalize(raw), want,
                           "normalize(\"\(raw)\")")
        }
    }

    /// Merchants NOT in the alias table fall through to generic clean-up:
    /// acquirer prefix + trailing city stripped, title-cased.
    func testGenericCleanup() {
        XCTAssertEqual(MerchantNormalizer.normalize("NAYAXAU*DATATEK PAYMENT LONDON"),
                       "Datatek Payment")
        XCTAssertEqual(MerchantNormalizer.normalize("Latymers - Hammersmith  London"),
                       "Latymers - Hammersmith",
                       "only the trailing CITY (London) is stripped, the district stays")
    }

    /// A payment credit normalises to a stable label (matches the parser's own).
    func testPaymentReceived() {
        XCTAssertEqual(MerchantNormalizer.normalize("PAYMENT RECEIVED - THANK YOU"),
                       "Payment Received")
    }

    /// Same real-world merchant reached via two different raw descriptors must
    /// collapse to ONE display name (consistent analytics, per the spec).
    func testConsistentNameAcrossDescriptors() {
        let dojo1 = MerchantNormalizer.normalize("DOJO*THE CRAFT BEER CO  LONDON")
        let dojo2 = MerchantNormalizer.normalize("THE CRAFT BEER CO SE1")
        XCTAssertEqual(dojo1, dojo2, "Dojo-prefixed and bare descriptors must agree")

        let dental1 = MerchantNormalizer.normalize("CARE DENTAL PLATINUM    LONDON")
        let dental2 = MerchantNormalizer.normalize("CAREDENTALPLATINUM.COM  CRAWLEY")
        XCTAssertEqual(dental1, dental2, "the two dental descriptors are one merchant")
    }

    /// Never returns an empty string for a non-empty input.
    func testNeverEmpty() {
        for raw in ["X", "12345", "DOJO*", "   ", "AB*CD"] {
            let n = MerchantNormalizer.normalize(raw)
            if !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                XCTAssertFalse(n.isEmpty, "normalize(\"\(raw)\") should not be empty")
            }
        }
    }
}
