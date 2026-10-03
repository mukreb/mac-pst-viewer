import Foundation

/// A decoded MAPI property value.
public enum PropertyValue: CustomStringConvertible {
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case date(Date)
    /// A Unicode string (PT_UNICODE).
    case string(String)
    /// An 8-bit string (PT_STRING8) kept raw so it can be decoded with the right code page later.
    case string8([UInt8])
    case binary([UInt8])
    case guid([UInt8])
    case object(nid: UInt32, size: UInt32)
    case multi([PropertyValue])
    case error(UInt32)

    // Property types
    static let PT_SHORT: UInt16 = 0x0002
    static let PT_LONG: UInt16 = 0x0003
    static let PT_FLOAT: UInt16 = 0x0004
    static let PT_DOUBLE: UInt16 = 0x0005
    static let PT_CURRENCY: UInt16 = 0x0006
    static let PT_APPTIME: UInt16 = 0x0007
    static let PT_ERROR: UInt16 = 0x000A
    static let PT_BOOLEAN: UInt16 = 0x000B
    static let PT_OBJECT: UInt16 = 0x000D
    static let PT_I8: UInt16 = 0x0014
    static let PT_STRING8: UInt16 = 0x001E
    static let PT_UNICODE: UInt16 = 0x001F
    static let PT_SYSTIME: UInt16 = 0x0040
    static let PT_CLSID: UInt16 = 0x0048
    static let PT_BINARY: UInt16 = 0x0102
    static let MV_FLAG: UInt16 = 0x1000

    static func isFixed8(_ t: UInt16) -> Bool {
        [PT_DOUBLE, PT_CURRENCY, PT_APPTIME, PT_I8, PT_SYSTIME].contains(t)
    }

    static func isVariable(_ t: UInt16) -> Bool {
        t & MV_FLAG != 0 || [PT_STRING8, PT_UNICODE, PT_BINARY, PT_CLSID, PT_OBJECT].contains(t) || isFixed8(t)
    }

    /// Decodes a value stored in a fixed-width cell (little-endian, already padded to 8 bytes when needed).
    static func decodeFixed(type: UInt16, bytes b: [UInt8]) -> PropertyValue? {
        switch type {
        case PT_SHORT: return .int(Int64(Int16(bitPattern: b.u16(0))))
        case PT_LONG: return .int(Int64(Int32(bitPattern: b.u32(0))))
        case PT_ERROR: return .error(b.u32(0))
        case PT_FLOAT: return .double(Double(Float(bitPattern: b.u32(0))))
        case PT_BOOLEAN: return .bool(b.u8(0) != 0)
        case PT_DOUBLE: return .double(Double(bitPattern: b.u64(0)))
        case PT_APPTIME: return FileTime.oleDate(Double(bitPattern: b.u64(0))).map { .date($0) } ?? .double(Double(bitPattern: b.u64(0)))
        case PT_CURRENCY: return .double(Double(Int64(bitPattern: b.u64(0))) / 10000.0)
        case PT_I8: return .int(Int64(bitPattern: b.u64(0)))
        case PT_SYSTIME: return FileTime.date(b.u64(0)).map { .date($0) } ?? .int(Int64(bitPattern: b.u64(0)))
        default: return nil
        }
    }

    /// Decodes a PC/TC value; `inline` is either the value itself (<= 4 bytes) or an HNID.
    static func decode(type: UInt16, inline: UInt32, heap: Heap) throws -> PropertyValue {
        switch type {
        case PT_SHORT: return .int(Int64(Int16(truncatingIfNeeded: inline)))
        case PT_LONG: return .int(Int64(Int32(bitPattern: inline)))
        case PT_ERROR: return .error(inline)
        case PT_FLOAT: return .double(Double(Float(bitPattern: inline)))
        case PT_BOOLEAN: return .bool(inline & 0xFF != 0)
        default: break
        }
        let bytes = try heap.value(inline)
        if isFixed8(type) {
            return decodeFixed(type: type, bytes: bytes) ?? .binary(bytes)
        }
        switch type {
        case PT_UNICODE: return .string(Text.utf16(bytes))
        case PT_STRING8: return .string8(bytes)
        case PT_BINARY: return .binary(bytes)
        case PT_CLSID: return .guid(bytes)
        case PT_OBJECT:
            return .object(nid: bytes.u32(0), size: bytes.u32(4))
        default:
            if type & MV_FLAG != 0 { return decodeMulti(type: type & ~MV_FLAG, bytes: bytes) }
            return .binary(bytes)
        }
    }

    private static func decodeMulti(type: UInt16, bytes: [UInt8]) -> PropertyValue {
        var items: [PropertyValue] = []
        let fixedSize: Int? = {
            switch type {
            case PT_SHORT: return 2
            case PT_LONG, PT_FLOAT, PT_ERROR, PT_BOOLEAN: return 4
            case PT_DOUBLE, PT_CURRENCY, PT_APPTIME, PT_I8, PT_SYSTIME: return 8
            case PT_CLSID: return 16
            default: return nil
            }
        }()
        if let size = fixedSize {
            var o = 0
            while o + size <= bytes.count {
                let chunk = Array(bytes[o..<(o + size)])
                if type == PT_CLSID {
                    items.append(.guid(chunk))
                } else {
                    var padded = chunk
                    padded.append(contentsOf: [UInt8](repeating: 0, count: Swift.max(0, 8 - size)))
                    if let v = decodeFixed(type: type, bytes: padded) { items.append(v) }
                }
                o += size
            }
        } else {
            let count = Int(bytes.u32(0))
            guard count < 100_000, 4 + count * 4 <= bytes.count else { return .multi([]) }
            var offsets = (0..<count).map { Int(bytes.u32(4 + $0 * 4)) }
            offsets.append(bytes.count)
            for i in 0..<count {
                let s = offsets[i], e = offsets[i + 1]
                guard s <= e, e <= bytes.count else { continue }
                let chunk = Array(bytes[s..<e])
                switch type {
                case PT_UNICODE: items.append(.string(Text.utf16(chunk)))
                case PT_STRING8: items.append(.string8(chunk))
                default: items.append(.binary(chunk))
                }
            }
        }
        return .multi(items)
    }

    // MARK: Convenience accessors

    public var intValue: Int64? {
        switch self {
        case .int(let v): return v
        case .bool(let b): return b ? 1 : 0
        case .double(let d): return Int64(d)
        default: return nil
        }
    }

    public var dateValue: Date? {
        if case .date(let d) = self { return d }
        return nil
    }

    public var bytesValue: [UInt8]? {
        switch self {
        case .binary(let b), .string8(let b), .guid(let b): return b
        case .string(let s): return Array(s.utf8)
        default: return nil
        }
    }

    public func stringValue(codepage: Int) -> String? {
        switch self {
        case .string(let s): return s
        case .string8(let b): return Text.decode(b, codepage: codepage)
        case .int(let v): return String(v)
        case .multi(let items): return items.compactMap { $0.stringValue(codepage: codepage) }.joined(separator: "; ")
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .int(let v): return String(v)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        case .string(let s): return s
        case .string8(let b): return Text.decode(b, codepage: 1252)
        case .binary(let b):
            let hex = b.prefix(64).map { String(format: "%02X", $0) }.joined(separator: " ")
            return b.count > 64 ? "\(hex) … (\(b.count) bytes)" : hex
        case .guid(let b): return Text.guidString(b)
        case .object(let nid, let size): return "object nid=0x\(String(nid, radix: 16)) size=\(size)"
        case .multi(let items): return "[" + items.map(\.description).joined(separator: ", ") + "]"
        case .error(let e): return String(format: "error 0x%08X", e)
        }
    }
}

/// A single property as shown in the "all properties" inspector.
public struct Property: Identifiable {
    public let id: UInt16
    public let type: UInt16
    public let value: PropertyValue
    public var tag: UInt32 { UInt32(id) << 16 | UInt32(type) }
    public var name: String { PropertyNames.name(for: id) }
}

/// Well-known property identifiers.
public enum PropID {
    public static let importance: UInt16 = 0x0017
    public static let messageClass: UInt16 = 0x001A
    public static let priority: UInt16 = 0x0026
    public static let sensitivity: UInt16 = 0x0036
    public static let subject: UInt16 = 0x0037
    public static let clientSubmitTime: UInt16 = 0x0039
    public static let sentRepresentingName: UInt16 = 0x0042
    public static let sentRepresentingAddrType: UInt16 = 0x0064
    public static let sentRepresentingEmail: UInt16 = 0x0065
    public static let startDate: UInt16 = 0x0060
    public static let endDate: UInt16 = 0x0061
    public static let conversationTopic: UInt16 = 0x0070
    public static let transportHeaders: UInt16 = 0x007D
    public static let recipientType: UInt16 = 0x0C15
    public static let senderName: UInt16 = 0x0C1A
    public static let senderAddrType: UInt16 = 0x0C1E
    public static let senderEmail: UInt16 = 0x0C1F
    public static let displayBcc: UInt16 = 0x0E02
    public static let displayCc: UInt16 = 0x0E03
    public static let displayTo: UInt16 = 0x0E04
    public static let messageDeliveryTime: UInt16 = 0x0E06
    public static let messageFlags: UInt16 = 0x0E07
    public static let messageSize: UInt16 = 0x0E08
    public static let attachSize: UInt16 = 0x0E20
    public static let hasAttachments: UInt16 = 0x0E1B
    public static let body: UInt16 = 0x1000
    public static let rtfCompressed: UInt16 = 0x1009
    public static let html: UInt16 = 0x1013
    public static let internetMessageID: UInt16 = 0x1035
    public static let displayName: UInt16 = 0x3001
    public static let addrType: UInt16 = 0x3002
    public static let emailAddress: UInt16 = 0x3003
    public static let comment: UInt16 = 0x3004
    public static let creationTime: UInt16 = 0x3007
    public static let lastModificationTime: UInt16 = 0x3008
    public static let contentCount: UInt16 = 0x3602
    public static let contentUnread: UInt16 = 0x3603
    public static let subfolders: UInt16 = 0x360A
    public static let containerClass: UInt16 = 0x3613
    public static let attachData: UInt16 = 0x3701
    public static let attachExtension: UInt16 = 0x3703
    public static let attachFilename: UInt16 = 0x3704
    public static let attachMethod: UInt16 = 0x3705
    public static let attachLongFilename: UInt16 = 0x3707
    public static let attachMimeTag: UInt16 = 0x370E
    public static let attachContentID: UInt16 = 0x3712
    public static let attachFlags: UInt16 = 0x3714
    public static let attachmentHidden: UInt16 = 0x7FFE
    public static let smtpAddress: UInt16 = 0x39FE
    public static let givenName: UInt16 = 0x3A06
    public static let businessPhone: UInt16 = 0x3A08
    public static let homePhone: UInt16 = 0x3A09
    public static let surname: UInt16 = 0x3A11
    public static let companyName: UInt16 = 0x3A16
    public static let title: UInt16 = 0x3A17
    public static let department: UInt16 = 0x3A18
    public static let mobilePhone: UInt16 = 0x3A1C
    public static let businessFax: UInt16 = 0x3A24
    public static let homeCity: UInt16 = 0x3A59
    public static let homeStreet: UInt16 = 0x3A5D
    public static let businessAddressCity: UInt16 = 0x3A27
    public static let businessAddressStreet: UInt16 = 0x3A29
    public static let businessHomePage: UInt16 = 0x3A51
    public static let birthday: UInt16 = 0x3A42
    public static let internetCodepage: UInt16 = 0x3FDE
    public static let messageCodepage: UInt16 = 0x3FFD
    public static let recordKey: UInt16 = 0x0FF9
    public static let ltpRowID: UInt16 = 0x67F2
    public static let senderSMTP: UInt16 = 0x5D01
    public static let sentRepresentingSMTP: UInt16 = 0x5D02
}

enum PropertyNames {
    static let names: [UInt16: String] = [
        0x0002: "AlternateRecipientAllowed", 0x0017: "Importance", 0x001A: "MessageClass",
        0x0023: "OriginatorDeliveryReportRequested", 0x0026: "Priority", 0x0029: "ReadReceiptRequested",
        0x002B: "RecipientReassignmentProhibited", 0x002E: "OriginalSensitivity", 0x0036: "Sensitivity",
        0x0037: "Subject", 0x0039: "ClientSubmitTime", 0x003B: "SentRepresentingSearchKey",
        0x003D: "SubjectPrefix", 0x003F: "ReceivedByEntryId", 0x0040: "ReceivedByName",
        0x0041: "SentRepresentingEntryId", 0x0042: "SentRepresentingName", 0x0043: "ReceivedRepresentingEntryId",
        0x0044: "ReceivedRepresentingName", 0x004F: "ReplyRecipientEntries", 0x0050: "ReplyRecipientNames",
        0x0051: "ReceivedBySearchKey", 0x0052: "ReceivedRepresentingSearchKey", 0x0057: "MessageToMe",
        0x0058: "MessageCcMe", 0x0060: "StartDate", 0x0061: "EndDate", 0x0064: "SentRepresentingAddressType",
        0x0065: "SentRepresentingEmailAddress", 0x0070: "ConversationTopic", 0x0071: "ConversationIndex",
        0x0075: "ReceivedByAddressType", 0x0076: "ReceivedByEmailAddress", 0x0077: "ReceivedRepresentingAddressType",
        0x0078: "ReceivedRepresentingEmailAddress", 0x007D: "TransportMessageHeaders", 0x0C15: "RecipientType",
        0x0C17: "ReplyRequested", 0x0C19: "SenderEntryId", 0x0C1A: "SenderName", 0x0C1D: "SenderSearchKey",
        0x0C1E: "SenderAddressType", 0x0C1F: "SenderEmailAddress", 0x0E01: "DeleteAfterSubmit",
        0x0E02: "DisplayBcc", 0x0E03: "DisplayCc", 0x0E04: "DisplayTo", 0x0E06: "MessageDeliveryTime",
        0x0E07: "MessageFlags", 0x0E08: "MessageSize", 0x0E17: "MessageStatus", 0x0E1B: "HasAttachments",
        0x0E1D: "NormalizedSubject", 0x0E1F: "RtfInSync", 0x0E20: "AttachSize", 0x0E21: "AttachNumber",
        0x0E2B: "ToDoItemFlags", 0x0E79: "TrustSender", 0x0FF4: "Access", 0x0FF7: "AccessLevel",
        0x0FF9: "RecordKey", 0x0FFE: "ObjectType", 0x0FFF: "EntryId", 0x1000: "Body", 0x1006: "RtfSyncBodyCrc",
        0x1007: "RtfSyncBodyCount", 0x1008: "RtfSyncBodyTag", 0x1009: "RtfCompressed", 0x1010: "RtfSyncPrefixCount",
        0x1011: "RtfSyncTrailingCount", 0x1013: "Html", 0x1035: "InternetMessageId", 0x1039: "InternetReferences",
        0x1042: "InReplyToId", 0x1080: "IconIndex", 0x1081: "LastVerbExecuted", 0x1082: "LastVerbExecutionTime",
        0x1090: "FlagStatus", 0x1091: "FlagCompleteTime", 0x10F4: "AttributeHidden", 0x10F6: "AttributeReadOnly",
        0x3001: "DisplayName", 0x3002: "AddressType", 0x3003: "EmailAddress", 0x3004: "Comment",
        0x3007: "CreationTime", 0x3008: "LastModificationTime", 0x300B: "SearchKey", 0x3416: "StoreRecordKey",
        0x35DF: "ValidFolderMask", 0x35E0: "IpmSubtreeEntryId", 0x35E2: "IpmOutboxEntryId",
        0x35E3: "IpmWastebasketEntryId", 0x35E4: "IpmSentMailEntryId", 0x3602: "ContentCount",
        0x3603: "ContentUnreadCount", 0x360A: "Subfolders", 0x3613: "ContainerClass", 0x36D0: "IpmAppointmentEntryId",
        0x36D1: "IpmContactEntryId", 0x36D2: "IpmJournalEntryId", 0x36D3: "IpmNoteEntryId", 0x36D4: "IpmTaskEntryId",
        0x3701: "AttachData", 0x3702: "AttachEncoding", 0x3703: "AttachExtension", 0x3704: "AttachFilename",
        0x3705: "AttachMethod", 0x3707: "AttachLongFilename", 0x370B: "RenderingPosition", 0x370E: "AttachMimeTag",
        0x3712: "AttachContentId", 0x3713: "AttachContentLocation", 0x3714: "AttachFlags", 0x3900: "DisplayType",
        0x39FE: "SmtpAddress", 0x39FF: "AddressBookDisplayNamePrintable", 0x3A00: "Account", 0x3A06: "GivenName",
        0x3A08: "BusinessTelephoneNumber", 0x3A09: "HomeTelephoneNumber", 0x3A0F: "MessageHandlingSystemCommonName",
        0x3A11: "Surname", 0x3A16: "CompanyName", 0x3A17: "Title", 0x3A18: "DepartmentName",
        0x3A19: "OfficeLocation", 0x3A1C: "MobileTelephoneNumber", 0x3A24: "BusinessFaxNumber",
        0x3A26: "Country", 0x3A27: "Locality", 0x3A28: "StateOrProvince", 0x3A29: "StreetAddress",
        0x3A2A: "PostalCode", 0x3A40: "SendRichInfo", 0x3A42: "Birthday", 0x3A45: "DisplayNamePrefix",
        0x3A51: "BusinessHomePage", 0x3A59: "HomeAddressCity", 0x3A5D: "HomeAddressStreet",
        0x3FDE: "InternetCodepage", 0x3FF1: "MessageLocaleId", 0x3FF8: "CreatorName", 0x3FF9: "CreatorEntryId",
        0x3FFA: "LastModifierName", 0x3FFD: "MessageCodepage", 0x4019: "SenderFlags",
        0x401A: "SentRepresentingFlags", 0x5FF6: "RecipientDisplayName", 0x5FF7: "RecipientEntryId",
        0x5FFD: "RecipientFlags", 0x5FDF: "RecipientOrder", 0x67F2: "LtpRowId", 0x67F3: "LtpRowVersion",
        0x6619: "UserEntryId", 0x7FFA: "AttachmentLinkId", 0x7FFE: "AttachmentHidden",
        0x7FFF: "AttachmentContactPhoto", 0x0E12: "MessageRecipients", 0x0E13: "MessageAttachments",
        0x0E05: "ParentDisplay", 0x0E09: "ParentEntryId", 0x0E0F: "Responsibility", 0x0E14: "SubmitFlags",
        0x0E28: "PrimarySendAccount", 0x0E29: "NextSendAcct", 0x5D01: "SenderSmtpAddress", 0x5D02: "SentRepresentingSmtpAddress",
    ]

    static func name(for id: UInt16) -> String {
        if let n = names[id] { return n }
        if id >= 0x8000 { return "Named 0x\(String(format: "%04X", id))" }
        return "0x\(String(format: "%04X", id))"
    }
}
