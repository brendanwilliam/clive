import CloudKit
import Foundation
import CliveCore

public enum CloudRendezvousError: LocalizedError, Sendable {
    case accountUnavailable
    case entitlementUnavailable
    case malformedRecord

    public var errorDescription: String? {
        switch self {
        case .accountUnavailable: "Sign in to iCloud with the same Apple Account on both devices."
        case .entitlementUnavailable: "Cellular access requires the signed Clive Mac app with its CloudKit entitlement."
        case .malformedRecord: "The encrypted rendezvous record is malformed."
        }
    }
}

public final class CloudRendezvousStore: @unchecked Sendable {
    public static let zoneName = "CliveRendezvousV1"
    public static let subscriptionID = "clive-rendezvous-v1"
    private let containerIdentifier: String
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName) }

    public init(containerIdentifier: String) {
        self.containerIdentifier = containerIdentifier
        container = CKContainer(identifier: containerIdentifier)
    }

    public func prepare() async throws -> String {
        guard try await accountStatus() == .available else { throw CloudRendezvousError.accountUnavailable }
        let user = try await userRecordID()
        _ = try await saveZone(CKRecordZone(zoneID: zoneID))
        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let info = CKSubscription.NotificationInfo(); info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do { _ = try await saveSubscription(subscription) }
        catch let error as CKError where error.code == .serverRejectedRequest || error.code == .unknownItem { throw error }
        catch { /* Existing subscriptions and transient push setup do not block foreground fetches. */ }
        return RendezvousCrypto.accountBinding(containerIdentifier: containerIdentifier, userRecordName: user.recordName)
    }

    public func save(_ envelope: RendezvousEnvelope, recordName: String, recordType: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record["envelope"] = try JSONEncoder().encode(envelope) as CKRecordValue
        record["expiresAt"] = envelope.expiresAt as CKRecordValue
        _ = try await saveRecord(record)
    }

    public func fetch(recordName: String) async throws -> RendezvousEnvelope? {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do {
            let record = try await fetchRecord(recordID)
            guard let data = record["envelope"] as? Data else { throw CloudRendezvousError.malformedRecord }
            return try JSONDecoder().decode(RendezvousEnvelope.self, from: data)
        } catch let error as CKError where error.code == .unknownItem { return nil }
    }

    public func delete(recordName: String) async throws {
        let recordID = CKRecord.ID(recordName: recordName, zoneID: zoneID)
        do { _ = try await deleteRecord(recordID) }
        catch let error as CKError where error.code == .unknownItem { return }
    }

    private func accountStatus() async throws -> CKAccountStatus { try await withCheckedThrowingContinuation { continuation in container.accountStatus { status, error in continuation.resume(with: error.map(Result.failure) ?? .success(status)) } } }
    private func userRecordID() async throws -> CKRecord.ID { try await withCheckedThrowingContinuation { continuation in container.fetchUserRecordID { value, error in continuation.resume(with: error.map(Result.failure) ?? value.map(Result.success) ?? .failure(CloudRendezvousError.accountUnavailable)) } } }
    private func saveZone(_ zone: CKRecordZone) async throws -> CKRecordZone { try await withCheckedThrowingContinuation { continuation in database.save(zone) { value, error in continuation.resume(with: error.map(Result.failure) ?? value.map(Result.success) ?? .failure(CloudRendezvousError.malformedRecord)) } } }
    private func saveSubscription(_ subscription: CKSubscription) async throws -> CKSubscription { try await withCheckedThrowingContinuation { continuation in database.save(subscription) { value, error in continuation.resume(with: error.map(Result.failure) ?? value.map(Result.success) ?? .failure(CloudRendezvousError.malformedRecord)) } } }
    private func saveRecord(_ record: CKRecord) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(recordsToSave: [record])
            operation.savePolicy = .allKeys
            operation.isAtomic = true
            operation.modifyRecordsResultBlock = { result in
                continuation.resume(with: result.map { record })
            }
            database.add(operation)
        }
    }
    private func fetchRecord(_ id: CKRecord.ID) async throws -> CKRecord { try await withCheckedThrowingContinuation { continuation in database.fetch(withRecordID: id) { value, error in continuation.resume(with: error.map(Result.failure) ?? value.map(Result.success) ?? .failure(CloudRendezvousError.malformedRecord)) } } }
    private func deleteRecord(_ id: CKRecord.ID) async throws -> CKRecord.ID { try await withCheckedThrowingContinuation { continuation in database.delete(withRecordID: id) { value, error in continuation.resume(with: error.map(Result.failure) ?? value.map(Result.success) ?? .failure(CloudRendezvousError.malformedRecord)) } } }
}
