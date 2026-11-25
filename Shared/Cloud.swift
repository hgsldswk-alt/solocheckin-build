import CloudKit
import Foundation

extension ZoneKey {
    init(_ id: CKRecordZone.ID) { self.init(name: id.zoneName, owner: id.ownerName) }
    var id: CKRecordZone.ID { CKRecordZone.ID(zoneName: name, ownerName: owner) }
    static func owned(_ name: String) -> Self { Self(name: name, owner: CKCurrentUserDefaultName) }
    static func sender(_ pair: UUID) -> Self { .owned("check-\(pair.uuidString)") }
    static func receiver(_ pair: UUID) -> Self { .owned("return-\(pair.uuidString)") }
}

struct SharePreview: Identifiable {
    var id: String { zone.name }
    var pair: UUID
    var zone: ZoneKey
    var owner: String
    var title: String
    var isReturn: Bool
    var metadata: CKShare.Metadata?
}

actor Cloud {
    static let shared = Cloud()
    static let containerID = "iCloud.com.hgsldswk.solocheckin"
    private lazy var container = CKContainer(identifier: Cloud.containerID)
    private var privateDB: CKDatabase { container.privateCloudDatabase }
    private var sharedDB: CKDatabase { container.sharedCloudDatabase }
    private let subscriptionID = "solo-shared-v1"

    private struct Snapshot {
        var token: CKServerChangeToken?
        var entries: [String: CloudCheckIn] = [:]
    }

    func account() async throws -> String {
        let status = try await container.accountStatus()
        if status == .noAccount { throw LocalError.signedOut }
        guard status == .available else { throw LocalError.unavailable }
        return try await container.userRecordID().recordName
    }

    func requireAccount(_ value: String) async throws {
        guard try await account() == value else { throw LocalError.wrongAccount }
    }

    func subscribe() async throws {
        do {
            _ = try await sharedDB.subscription(for: subscriptionID)
        } catch let error as CKError where error.code == .unknownItem {
            let subscription = CKDatabaseSubscription(subscriptionID: subscriptionID)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await sharedDB.save(subscription)
        }
    }

    func participant(address: String) async throws -> String {
        let info = address.contains("@") ? CKUserIdentity.LookupInfo(emailAddress: address)
            : CKUserIdentity.LookupInfo(phoneNumber: address)
        let participant: CKShare.Participant = try await withCheckedThrowingContinuation { cont in
            let op = CKFetchShareParticipantsOperation(userIdentityLookupInfos: [info])
            var found: CKShare.Participant?
            op.perShareParticipantResultBlock = { _, result in
                if case .success(let p) = result { found = p }
            }
            op.fetchShareParticipantsResultBlock = { result in
                switch result {
                case .success:
                    if let found { cont.resume(returning: found) } else { cont.resume(throwing: LocalError.invalid) }
                case .failure(let error):
                    cont.resume(throwing: error)
                }
            }
            container.add(op)
        }
        guard let id = participant.userIdentity.userRecordID else { throw LocalError.invalid }
        return id.recordName
    }

    func invitation(zone: ZoneKey, value: Agreement, partner: String, account: String) async throws -> URL {
        try await requireAccount(account)
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zone.id)
        do {
            guard let existing = try await privateDB.record(for: shareID) as? CKShare,
                  existing.publicPermission == .none,
                  existing.participants.contains(where: {
                      $0.role != .owner && $0.permission == .readOnly && $0.userIdentity.userRecordID?.recordName == partner
                  }), let link = existing.url else { throw LocalError.invalid }
            return link
        } catch let error as CKError where Self.gone(error) {
        }
        let id = CKRecord.ID(recordName: partner)
        let result = try await container.shareParticipants(forUserRecordIDs: [id])
        guard let participant = try result[id]?.get(), participant.userIdentity.userRecordID?.recordName == partner,
              partner != account else { throw LocalError.invalid }
        _ = try await privateDB.save(CKRecordZone(zoneID: zone.id))
        try await write(value, zone: zone, account: account)
        let share = CKShare(recordZoneID: zone.id)
        share.publicPermission = .none
        participant.role = .privateUser
        participant.permission = .readOnly
        share.addParticipant(participant)
        share[CKShare.SystemFieldKey.title] = value.alias as NSString
        try await requireAccount(account)
        guard let saved = try await privateDB.save(share) as? CKShare, let url = saved.url else { throw LocalError.invalid }
        return url
    }

    func invitationAccepted(pair: UUID, partner: String) async throws -> Bool {
        let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: ZoneKey.sender(pair).id)
        guard let share = try await privateDB.record(for: id) as? CKShare else { throw LocalError.invalid }
        return share.participants.contains {
            $0.userIdentity.userRecordID?.recordName == partner && $0.acceptanceStatus == .accepted && $0.permission == .readOnly
        }
    }

    func receiverClaim(_ receipt: WindowReceipt, pair: UUID, linked: Date, account: String) async throws -> Agreement {
        let zone = ZoneKey.receiver(pair)
        do { return try await read(zone, owned: true) }
        catch let error as CKError where Self.gone(error) && error.code != .permissionFailure {
            try await requireAccount(account)
            _ = try await privateDB.save(CKRecordZone(zoneID: zone.id))
            let value = Agreement(pair: pair, alias: "", receipt: receipt, linked: linked)
            do { try await write(value, zone: zone, account: account) }
            catch LocalError.stale {}
            catch let conflict as CKError where conflict.code == .serverRecordChanged {}
            return try await read(zone, owned: true)
        }
    }

    func write(_ value: Agreement, zone: ZoneKey, account: String) async throws {
        try await requireAccount(account)
        let id = rootID(zone)
        let fetched: CKRecord?
        do {
            fetched = try await privateDB.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            fetched = nil
        }
        let record: CKRecord
        if let fetched {
            record = fetched
            let old = try decodeAgreement(record)
            guard old.pair == value.pair else { throw LocalError.invalid }
            if let oldReceipt = old.receipt, let proposed = value.receipt {
                guard proposed.device == oldReceipt.device, proposed.confirmed >= oldReceipt.confirmed else {
                    throw LocalError.stale
                }
            }
            if old == value { return }
        } else {
            record = CKRecord(recordType: "SoloAgreement", recordID: id)
        }
        record["payload"] = try JSONEncoder().encode(value) as NSData
        try await requireAccount(account)
        _ = try await privateDB.save(record)
    }

    func claim(_ receipt: WindowReceipt, pair: UUID, account: String) async throws {
        try await requireAccount(account)
        let record = try await privateDB.record(for: rootID(.receiver(pair)))
        var existing = try decodeAgreement(record)
        guard existing.pair == pair, existing.receipt?.ended != true else { throw LocalError.invalid }
        existing.receipt = receipt
        record["payload"] = try JSONEncoder().encode(existing) as NSData
        try await requireAccount(account)
        _ = try await privateDB.save(record)
    }

    func read(_ zone: ZoneKey, owned: Bool = false) async throws -> Agreement {
        let record = try await (owned ? privateDB : sharedDB).record(for: rootID(zone))
        return try decodeAgreement(record)
    }

    private func decodeAgreement(_ record: CKRecord) throws -> Agreement {
        guard let bytes = record["payload"] as? Data, bytes.count < 48_000 else { throw LocalError.invalid }
        let value = try JSONDecoder().decode(Agreement.self, from: bytes)
        guard value.alias.count <= 40, value.plan?.valid != false else { throw LocalError.invalid }
        return value
    }

    func preview(url: URL) async throws -> SharePreview {
        let results = try await container.shareMetadatas(for: [url])
        guard let metadata = try results[url]?.get() else { throw LocalError.invalid }
        return try Self.preview(metadata)
    }

    nonisolated static func preview(_ metadata: CKShare.Metadata) throws -> SharePreview {
        let name = metadata.share.recordID.zoneID.zoneName
        let isReturn = name.hasPrefix("return-")
        guard metadata.containerIdentifier == containerID,
              metadata.share.recordID.recordName == CKRecordNameZoneWideShare,
              metadata.participantRole == .privateUser, metadata.participantPermission == .readOnly,
              metadata.share.publicPermission == .none,
              let owner = metadata.ownerIdentity.userRecordID?.recordName, owner != CKCurrentUserDefaultName,
              isReturn || name.hasPrefix("check-"),
              let pair = UUID(uuidString: String(name.dropFirst(isReturn ? 7 : 6))) else { throw LocalError.invalid }
        let title = metadata.share[CKShare.SystemFieldKey.title] as? String ?? ""
        let zone = ZoneKey(name: name, owner: owner)
        return SharePreview(pair: pair, zone: zone, owner: owner, title: String(title.prefix(40)), isReturn: isReturn, metadata: metadata)
    }

    func accept(_ preview: SharePreview, account: String) async throws -> Agreement {
        try await requireAccount(account)
        guard preview.owner != account, let metadata = preview.metadata else { throw LocalError.invalid }
        if metadata.participantStatus == .pending {
            _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKShare, Error>) in
                container.accept(metadata) { share, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let share { continuation.resume(returning: share) }
                    else { continuation.resume(throwing: LocalError.invalid) }
                }
            }
        }
        let value = try await read(preview.zone)
        guard value.pair == preview.pair,
              preview.isReturn ? (value.plan == nil && value.receipt != nil) : (value.plan != nil && value.receipt == nil)
        else { throw LocalError.invalid }
        return value
    }

    func upload(_ check: CheckIn, pair: UUID, account: String) async throws -> Date {
        try await requireAccount(account)
        let id = CKRecord.ID(recordName: "entry-" + check.id, zoneID: ZoneKey.sender(pair).id)
        do {
            let existing = try await privateDB.record(for: id)
            guard let uploaded = existing.creationDate else { throw LocalError.invalid }
            return uploaded
        } catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "SoloCheck", recordID: id)
            record["payload"] = try JSONEncoder().encode(check) as NSData
            do {
                try await requireAccount(account)
                let saved = try await privateDB.save(record)
                guard let uploaded = saved.creationDate else { throw LocalError.invalid }
                return uploaded
            } catch let conflict as CKError where conflict.code == .serverRecordChanged {
                let existing = try await privateDB.record(for: id)
                guard let uploaded = existing.creationDate else { throw LocalError.invalid }
                return uploaded
            }
        }
    }

    func changes(_ zone: ZoneKey, since cutoff: Date, entries: [String: CloudCheckIn], tokenData: Data?) async throws
        -> (entries: [String: CloudCheckIn], token: Data?) {
        let token = tokenData.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
        let previous = token.map { Snapshot(token: $0, entries: entries) } ?? Snapshot()
        let snapshot: Snapshot
        do {
            snapshot = try await fetchChanges(zone, since: cutoff, starting: previous)
        } catch let error as CKError where error.code == .changeTokenExpired {
            snapshot = try await fetchChanges(zone, since: cutoff, starting: Snapshot())
        }
        let encoded = snapshot.token.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return (snapshot.entries, encoded)
    }

    private func fetchChanges(_ zone: ZoneKey, since cutoff: Date, starting: Snapshot) async throws -> Snapshot {
        var snapshot = starting
        var more: Bool
        repeat {
            let page = try await sharedDB.recordZoneChanges(inZoneWith: zone.id, since: snapshot.token,
                                                            desiredKeys: ["payload"], resultsLimit: 100)
            for (id, result) in page.modificationResultsByID where id.recordName.hasPrefix("entry-") {
                let record = try result.get().record
                guard let data = record["payload"] as? Data, data.count < 4096,
                      let check = try? JSONDecoder().decode(CheckIn.self, from: data),
                      id.recordName == "entry-" + check.id, let uploaded = record.creationDate else { continue }
                snapshot.entries[check.id] = CloudCheckIn(entry: check, uploaded: uploaded)
            }
            for deletion in page.deletions where deletion.recordID.recordName.hasPrefix("entry-") {
                snapshot.entries.removeValue(forKey: String(deletion.recordID.recordName.dropFirst(6)))
            }
            snapshot.token = page.changeToken
            more = page.moreComing
        } while more
        snapshot.entries = snapshot.entries.filter { $0.value.entry.window.expiry >= cutoff }
        return snapshot
    }

    func newestEntry(_ zone: ZoneKey, deleting ids: [String], account: String) async throws {
        guard !ids.isEmpty else { return }
        try await requireAccount(account)
        let records = ids.map { CKRecord.ID(recordName: "entry-" + $0, zoneID: zone.id) }
        let result = try await privateDB.modifyRecords(saving: [], deleting: records, atomically: false)
        for status in result.deleteResults.values {
            do { try status.get() } catch let error as CKError where Self.gone(error) {}
        }
    }

    func revoke(_ item: Revocation, account: String) async throws {
        try await requireAccount(account)
        do {
            if item.shared {
                let id = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: item.zone.id)
                _ = try await sharedDB.deleteRecord(withID: id)
            } else {
                _ = try await privateDB.deleteRecordZone(withID: item.zone.id)
            }
        } catch let error as CKError where Self.gone(error) {}
    }

    private func rootID(_ zone: ZoneKey) -> CKRecord.ID {
        CKRecord.ID(recordName: "agreement", zoneID: zone.id)
    }

    nonisolated static func gone(_ error: CKError) -> Bool {
        [.unknownItem, .zoneNotFound, .userDeletedZone, .permissionFailure].contains(error.code)
    }
}
