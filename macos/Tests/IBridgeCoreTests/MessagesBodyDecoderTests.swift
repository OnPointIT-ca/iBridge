import Foundation
import XCTest
@testable import IBridgeCore

final class MessagesBodyDecoderTests: XCTestCase {
    func testRealFoundationStringArchives() {
        for text in ["", "hello", "quote: \"hi\"\nnext line\tend", "你好 café 🐈‍⬛ 🇨🇦", "\u{fffc}attachment"] {
            for object: Any in [text as NSString, NSMutableString(string: text)] {
                let archive = NSArchiver.archivedData(withRootObject: object)
                XCTAssertEqual(MessagesBodyDecoder.decode(archive), text)
            }
        }
    }

    func testRealFoundationAttributedStringArchives() {
        for text in ["", "Simple note", "你好 🐈‍⬛\n\"quoted\"", String(repeating: "abc", count: 1500)] {
            for object: Any in [NSAttributedString(string: text), NSMutableAttributedString(string: text)] {
                let archive = NSArchiver.archivedData(withRootObject: object)
                XCTAssertEqual(MessagesBodyDecoder.decode(archive), text)
            }
        }
    }

    func testRealAttributedRunsDoNotReplaceBodyWithMetadata() {
        let text = "one 🐈‍⬛ two\nthree"
        let attributed = NSMutableAttributedString(string: text)
        attributed.addAttributes([
            NSAttributedString.Key("__kIMMessagePartAttributeName"): NSNumber(value: 0),
            NSAttributedString.Key("metadata"): "This is not the message body"
        ], range: NSRange(location: 0, length: 3))
        attributed.addAttribute(NSAttributedString.Key("anotherAttribute"), value: "other string",
                                range: NSRange(location: 4, length: attributed.length - 4))
        XCTAssertEqual(MessagesBodyDecoder.decode(NSArchiver.archivedData(withRootObject: attributed)), text)
    }

    func testSyntheticStringsAndAllLengthWidths() {
        for length in [0, 1, 127, 128, 145, 146, 255, 256, 1024, 65_535, 65_536] {
            let text = String(repeating: "x", count: length)
            XCTAssertEqual(MessagesBodyDecoder.decode(stringArchive(Array(text.utf8))), text, "Length \(length)")
        }
        XCTAssertNil(MessagesBodyDecoder.decode(stringArchive(Array(String(repeating: "x", count: 65_537).utf8))))
    }

    func testBigEndianTypedstream() {
        XCTAssertEqual(MessagesBodyDecoder.decode(stringArchive(Array("big endian ✓".utf8), bigEndian: true)), "big endian ✓")
        let text = String(repeating: "🎵", count: 100)
        XCTAssertEqual(MessagesBodyDecoder.decode(stringArchive(Array(text.utf8), bigEndian: true)), text)
    }

    func testInvalidUTF8IsNotLossilyReturned() {
        for raw: [UInt8] in [[0xff], [0xc0, 0xaf], [0xf0, 0x9f], [0xed, 0xa0, 0x80]] {
            XCTAssertNil(MessagesBodyDecoder.decode(stringArchive(raw)))
        }
    }

    func testEveryTruncationAndTrailingBytesAreRejected() {
        let archive = NSArchiver.archivedData(withRootObject: NSAttributedString(string: "a message with attributes"))
        for length in 0..<archive.count {
            XCTAssertNil(MessagesBodyDecoder.decode(archive.prefix(length)), "Truncated at \(length)")
        }
        var trailing = archive
        trailing.append(0)
        XCTAssertNil(MessagesBodyDecoder.decode(trailing))
    }

    func testUnknownRootClassCannotSmuggleTextAsBody() {
        let archive = NSArchiver.archivedData(withRootObject: ["body": "NSString metadata and fake body"] as NSDictionary)
        XCTAssertNil(MessagesBodyDecoder.decode(archive))
        let textArchive = stringArchive(Array("message".utf8))
        var wrongClass = textArchive
        let range = wrongClass.range(of: Data("NSString".utf8))!
        wrongClass.replaceSubrange(range, with: Data("BadClass".utf8))
        XCTAssertNil(MessagesBodyDecoder.decode(wrongClass))
        var wrongVersion = textArchive
        wrongVersion[range.upperBound] = 2
        XCTAssertNil(MessagesBodyDecoder.decode(wrongVersion))
    }

    func testInvalidLengthsReferencesAndEncodings() {
        var invalidLength = stringArchive(Array("message".utf8))
        let payload = invalidLength.range(of: Data("message".utf8))!
        invalidLength.replaceSubrange((payload.lowerBound - 1)..<payload.upperBound, with: [0x82, 0xff, 0xff, 0xff, 0xff])
        XCTAssertNil(MessagesBodyDecoder.decode(invalidLength))
        let header = Array(stringArchive([]).prefix(16))
        for suffix: [UInt8] in [
            [0x91], // reserved tag
            [0x92], // nonexistent shared-string reference
            [0x84, 1, 64, 0x92], // nonexistent object reference
            [0x84, 1, 94], // unsupported pointer encoding
            [0x84, 4, 91, 57, 57, 93], // array missing element type
            [0x84, 1, 64, 0x84, 0x84, 0x92, 0, 0x92] // class reference points at pending object
        ] {
            XCTAssertNil(MessagesBodyDecoder.decode(Data(header + suffix)))
        }
    }

    func testBlobAndWorkLimits() {
        XCTAssertNil(MessagesBodyDecoder.decode(Data(repeating: 0x84, count: MessagesBodyDecoder.maximumArchiveBytes + 1)))
        let header = Array(stringArchive([]).prefix(16))
        // Huge repetition of a zero-byte encoding must not cause unbounded work.
        let encoding = Array("[1048576!]".utf8)
        XCTAssertNil(MessagesBodyDecoder.decode(Data(header + [0x84, UInt8(encoding.count)] + encoding)))
        let nesting = Array((String(repeating: "[1", count: 100) + "!" + String(repeating: "]", count: 100)).utf8)
        XCTAssertNil(MessagesBodyDecoder.decode(Data(header + [0x84] + integer(nesting.count) + nesting)))
    }

    func testOtherArchiveFamiliesAndRandomBinaryFailClosed() throws {
        let keyed = try NSKeyedArchiver.archivedData(withRootObject: NSAttributedString(string: "keyed"), requiringSecureCoding: true)
        XCTAssertNil(MessagesBodyDecoder.decode(keyed))
        XCTAssertNil(MessagesBodyDecoder.decode(Data("NSString\u{1}+fake\u{86}".utf8)))
        var state: UInt64 = 0x5a17
        for length in 0..<512 {
            let bytes = (0..<length).map { _ -> UInt8 in
                state = state &* 6_364_136_223_846_793_005 &+ 1
                return UInt8(truncatingIfNeeded: state >> 32)
            }
            XCTAssertNil(MessagesBodyDecoder.decode(Data(bytes)))
        }
    }

    /// Independent minimal v4 NSString archive; no private Apple data fixtures.
    private func stringArchive(_ utf8: [UInt8], bigEndian: Bool = false) -> Data {
        let header: [UInt8] = [4, 11] + Array((bigEndian ? "typedstream" : "streamtyped").utf8) + integer(1000, bigEndian: bigEndian)
        let stringClass: [UInt8] = [0x84, 0x84, 8] + Array("NSString".utf8) + [1]
        let rootClass: [UInt8] = [0x84, 0x84, 8] + Array("NSObject".utf8) + [0, 0x85]
        return Data(header + [0x84, 1, 64, 0x84] + stringClass + rootClass + [0x84, 1, 43] + integer(utf8.count, bigEndian: bigEndian) + utf8 + [0x86])
    }

    private func integer(_ value: Int, bigEndian: Bool = false) -> [UInt8] {
        if value < 128 || (146...255).contains(value) { return [UInt8(value)] }
        let width = value <= 65_535 ? 2 : 4
        let bytes = (0..<width).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return [width == 2 ? 0x81 : 0x82] + (bigEndian ? Array(bytes.reversed()) : bytes)
    }
}
