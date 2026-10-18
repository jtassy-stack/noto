import CloudKit
import Foundation

/// `FamilySyncRecord` ↔ `CKRecord`. Every field goes into `encryptedValues`:
/// end-to-end encrypted, unreadable by Apple and by nōto (which has no
/// server). The record type is `Kind.rawValue`, the record name is
/// `FamilySyncRecord.name`, the zone is the child's shared zone.
extension FamilySyncRecord {
    func ckRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
        let record = CKRecord(recordType: kind.rawValue, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        apply(to: record)
        return record
    }

    /// Writes the fields into `record`, an existing server record when
    /// updating (it carries the change tag), and clears the ones this
    /// version no longer sets.
    func apply(to record: CKRecord) {
        let values = record.encryptedValues
        for key in values.allKeys() where fields[key] == nil {
            values[key] = nil as String?
        }
        for (key, value) in fields {
            switch value {
            case .int(let v): values[key] = v
            case .double(let v): values[key] = v
            case .string(let v): values[key] = v
            case .date(let v): values[key] = v
            case .ints(let v): values[key] = v
            case .strings(let v): values[key] = v
            }
        }
    }

    /// Nil for a record type this build does not know.
    init?(ckRecord: CKRecord) {
        guard let kind = Kind(rawValue: ckRecord.recordType) else { return nil }
        let values = ckRecord.encryptedValues
        var fields: [String: Value] = [:]
        for key in values.allKeys() {
            // NSNumber reads as Int when integral, so Int comes before
            // Double; `FamilySyncRecord.double` accepts both.
            if let v: Date = values[key] { fields[key] = .date(v) }
            else if let v: String = values[key] { fields[key] = .string(v) }
            else if let v: [String] = values[key] { fields[key] = .strings(v) }
            else if let v: [Int] = values[key] { fields[key] = .ints(v) }
            else if let v: Int = values[key] { fields[key] = .int(v) }
            else if let v: Double = values[key] { fields[key] = .double(v) }
        }
        self.init(kind: kind, name: ckRecord.recordID.recordName, decodedFields: fields)
    }
}
