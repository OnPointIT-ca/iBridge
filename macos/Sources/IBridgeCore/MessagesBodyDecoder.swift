import Foundation

/// Extracts text from the macOS v4 typedstream form of Messages attributedBody.
/// This is a bounded data parser: it never invokes NSUnarchiver or constructs an
/// Objective-C class named in an archive. Unknown encodings fail closed.
/// Format references (independent implementation):
/// https://github.com/dgelessus/python-typedstream/blob/master/src/typedstream/stream.py
/// https://github.com/ReagentX/imessage-exporter/tree/develop/imessage-database/test_data/typedstream
internal enum MessagesBodyDecoder {
    static let maximumArchiveBytes = 1_048_576
    static let maximumTextBytes = 65_536

    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumArchiveBytes else { return nil }
        var parser = Parser(bytes: Array(data))
        return try? parser.body()
    }

    private enum Invalid: Error { case archive }
    private struct ArchivedClass: Equatable {
        let name: String
        let version: Int
    }
    private struct ArchivedObject {
        let classes: [ArchivedClass]
        let text: String?
    }
    private enum Reference {
        case pending, classes([ArchivedClass]), object(ArchivedObject), cString
    }
    private enum Value {
        case scalar, bytes([UInt8]), object(ArchivedObject)
    }
    private indirect enum Encoding {
        case primitive(UInt8), array(Int, Encoding), structure([Encoding])
    }

    private struct Parser {
        let bytes: [UInt8]
        var offset = 0
        var littleEndian = true
        var strings: [[UInt8]] = []
        var references: [Reference] = []
        var remainingValues = 32_768

        mutating func body() throws -> String {
            guard try byte() == 4, try byte() == 11 else { throw Invalid.archive }
            let signature = try take(11)
            if signature == Array("streamtyped".utf8) { littleEndian = true }
            else if signature == Array("typedstream".utf8) { littleEndian = false }
            else { throw Invalid.archive }
            guard try integer(signed: false) == 1000 else { throw Invalid.archive }
            let values = try group(depth: 0)
            guard values.count == 1, case .object(let root) = values[0],
                  let text = root.text, offset == bytes.count else { throw Invalid.archive }
            return text
        }

        mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else { throw Invalid.archive }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, count <= bytes.count - offset else { throw Invalid.archive }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }

        mutating func integer(head: UInt8? = nil, signed: Bool) throws -> Int {
            let first = try head ?? byte()
            if !(0x80...0x91).contains(first) {
                return signed ? Int(Int8(bitPattern: first)) : Int(first)
            }
            guard first == 0x81 || first == 0x82 else { throw Invalid.archive }
            let raw = try take(first == 0x81 ? 2 : 4)
            var number: UInt32 = 0
            for item in littleEndian ? Array(raw.reversed()) : raw { number = (number << 8) | UInt32(item) }
            if !signed { return Int(number) }
            return first == 0x81 ? Int(Int16(bitPattern: UInt16(number))) : Int(Int32(bitPattern: number))
        }

        mutating func unshared(head: UInt8? = nil) throws -> [UInt8] {
            let count = try integer(head: head, signed: false)
            return try take(count)
        }

        mutating func shared() throws -> [UInt8] {
            let head = try byte()
            if head == 0x84 {
                guard strings.count < 4096 else { throw Invalid.archive }
                let value = try unshared()
                guard value.count <= maximumTextBytes else { throw Invalid.archive }
                strings.append(value)
                return value
            }
            let index = try integer(head: head, signed: true) + 110
            guard strings.indices.contains(index) else { throw Invalid.archive }
            return strings[index]
        }

        mutating func reserve() throws -> Int {
            guard references.count < 4096 else { throw Invalid.archive }
            references.append(.pending)
            return references.count - 1
        }

        mutating func reference(_ head: UInt8) throws -> Reference {
            let index = try integer(head: head, signed: true) + 110
            guard references.indices.contains(index) else { throw Invalid.archive }
            return references[index]
        }

        mutating func classes(depth: Int) throws -> [ArchivedClass] {
            guard depth < 32 else { throw Invalid.archive }
            let head = try byte()
            if head == 0x85 { return [] }
            if head == 0x84 {
                let index = try reserve()
                let nameBytes = try shared()
                guard nameBytes.count <= 256, let name = String(bytes: nameBytes, encoding: .ascii),
                      !name.isEmpty else { throw Invalid.archive }
                let version = try integer(signed: true)
                let result = [ArchivedClass(name: name, version: version)] + (try classes(depth: depth + 1))
                guard result.count <= 16 else { throw Invalid.archive }
                references[index] = .classes(result)
                return result
            }
            guard case .classes(let result) = try reference(head) else { throw Invalid.archive }
            return result
        }

        func matches(_ classes: [ArchivedClass], _ names: [(String, Int)]) -> Bool {
            classes == names.map { ArchivedClass(name: $0.0, version: $0.1) }
        }

        mutating func object(depth: Int) throws -> Value {
            guard depth < 32 else { throw Invalid.archive }
            let head = try byte()
            if head == 0x85 { return .scalar }
            if head != 0x84 {
                guard case .object(let object) = try reference(head) else { throw Invalid.archive }
                return .object(object)
            }
            let index = try reserve()
            let hierarchy = try classes(depth: 0)
            guard !hierarchy.isEmpty else { throw Invalid.archive }
            let isString = matches(hierarchy, [("NSString", 1), ("NSObject", 0)]) ||
                matches(hierarchy, [("NSMutableString", 1), ("NSString", 1), ("NSObject", 0)])
            let isAttributed = matches(hierarchy, [("NSAttributedString", 0), ("NSObject", 0)]) ||
                matches(hierarchy, [("NSMutableAttributedString", 0), ("NSAttributedString", 0), ("NSObject", 0)])
            var text: String?
            var groups = 0
            while offset < bytes.count, bytes[offset] != 0x86 {
                let values = try group(depth: depth + 1)
                if groups == 0, isString {
                    guard values.count == 1, case .bytes(let raw) = values[0],
                          raw.count <= maximumTextBytes,
                          let decoded = String(bytes: raw, encoding: .utf8) else { throw Invalid.archive }
                    text = decoded
                } else if groups == 0, isAttributed {
                    guard values.count == 1, case .object(let body) = values[0],
                          matches(body.classes, [("NSString", 1), ("NSObject", 0)]) ||
                            matches(body.classes, [("NSMutableString", 1), ("NSString", 1), ("NSObject", 0)]),
                          let decoded = body.text else { throw Invalid.archive }
                    text = decoded
                }
                groups += 1
            }
            guard try byte() == 0x86, !isString || groups == 1,
                  (!isString && !isAttributed) || text != nil else { throw Invalid.archive }
            let result = ArchivedObject(classes: hierarchy, text: text)
            references[index] = .object(result)
            return .object(result)
        }

        mutating func group(depth: Int) throws -> [Value] {
            let raw = try shared()
            guard !raw.isEmpty, raw.count <= 1024 else { throw Invalid.archive }
            var position = 0
            var encodings: [Encoding] = []
            while position < raw.count {
                encodings.append(try encoding(raw, position: &position, depth: 0))
            }
            return try encodings.map { try value($0, depth: depth) }
        }

        func encoding(_ raw: [UInt8], position: inout Int, depth: Int) throws -> Encoding {
            guard depth < 16, position < raw.count else { throw Invalid.archive }
            let type = raw[position]
            position += 1
            if type == 0x5b { // [count elementType]
                var count = 0
                let begin = position
                while position < raw.count, (48...57).contains(raw[position]) {
                    count = count * 10 + Int(raw[position] - 48)
                    guard count <= maximumArchiveBytes else { throw Invalid.archive }
                    position += 1
                }
                guard position > begin else { throw Invalid.archive }
                let element = try encoding(raw, position: &position, depth: depth + 1)
                guard position < raw.count, raw[position] == 0x5d else { throw Invalid.archive }
                position += 1
                return .array(count, element)
            }
            if type == 0x7b { // {name=fieldTypes}
                while position < raw.count, raw[position] != 0x3d, raw[position] != 0x7d { position += 1 }
                guard position < raw.count, raw[position] == 0x3d else { throw Invalid.archive }
                position += 1
                var fields: [Encoding] = []
                while position < raw.count, raw[position] != 0x7d {
                    fields.append(try encoding(raw, position: &position, depth: depth + 1))
                }
                guard position < raw.count else { throw Invalid.archive }
                position += 1
                return .structure(fields)
            }
            guard Array("BcCsSiIlLqQfd*%:+#@!".utf8).contains(type) else { throw Invalid.archive }
            return .primitive(type)
        }

        mutating func value(_ encoding: Encoding, depth: Int) throws -> Value {
            guard depth < 32, remainingValues > 0 else { throw Invalid.archive }
            remainingValues -= 1
            switch encoding {
            case .array(let count, let type):
                if case .primitive(let code) = type, code == 99 || code == 67 {
                    _ = try take(count)
                } else {
                    guard count <= remainingValues else { throw Invalid.archive }
                    for _ in 0..<count { _ = try value(type, depth: depth + 1) }
                }
            case .structure(let fields):
                for field in fields { _ = try value(field, depth: depth + 1) }
            case .primitive(let type):
                switch type {
                case 64: return try object(depth: depth) // @
                case 43: return .bytes(try unshared()) // + UTF-8 NSString payload
                case 35: _ = try classes(depth: 0) // #
                case 58, 37: _ = try shared() // selector / atom
                case 42: // C string, in the common reference table
                    let head = try byte()
                    if head == 0x84 {
                        _ = try shared()
                        let index = try reserve()
                        references[index] = .cString
                    } else if head != 0x85 {
                        guard case .cString = try reference(head) else { throw Invalid.archive }
                    }
                case 66: guard try byte() <= 1 else { throw Invalid.archive }
                case 99, 67: _ = try byte()
                case 115, 105, 108, 113: _ = try integer(signed: true)
                case 83, 73, 76, 81: _ = try integer(signed: false)
                case 102, 100:
                    let head = try byte()
                    if head == 0x83 { _ = try take(type == 102 ? 4 : 8) }
                    else { _ = try integer(head: head, signed: true) }
                case 33: break // ignored field has no bytes
                default: throw Invalid.archive
                }
            }
            return .scalar
        }
    }
}
