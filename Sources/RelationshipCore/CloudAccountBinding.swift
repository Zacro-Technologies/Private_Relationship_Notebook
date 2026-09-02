import CloudKit
import CryptoKit
import Foundation

public enum CloudAccountResolution: Equatable, Sendable {
    case available(accountBinding: String)
    case noAccount
    case restricted
    case temporarilyUnavailable
    case failed(SyncIssue)

    public var localOnlyReason: LocalOnlyReason {
        switch self {
        case .available:
            .userChoice
        case .noAccount:
            .noAccount
        case .temporarilyUnavailable:
            .temporarilyUnavailable
        case .restricted:
            .restricted
        case .failed:
            .entitlementUnavailable
        }
    }
}

/// Boundary around CloudKit account metadata. Tests can supply a deterministic
/// resolver without signing in to iCloud or possessing entitlements.
@MainActor
public protocol CloudAccountResolving: AnyObject {
    func resolve(containerIdentifier: String) async -> CloudAccountResolution
}

@MainActor
public final class SystemCloudAccountResolver: CloudAccountResolving {
    public init() {}

    public func resolve(containerIdentifier: String) async -> CloudAccountResolution {
        let container = CKContainer(identifier: containerIdentifier)
        do {
            switch try await container.accountStatus() {
            case .available:
                let recordID = try await container.userRecordID()
                return .available(accountBinding: Self.accountBinding(
                    containerIdentifier: containerIdentifier,
                    recordName: recordID.recordName
                ))
            case .noAccount:
                return .noAccount
            case .restricted:
                return .restricted
            case .temporarilyUnavailable, .couldNotDetermine:
                return .temporarilyUnavailable
            @unknown default:
                return .failed(.account)
            }
        } catch let error as CKError {
            return .failed(Self.issue(for: error))
        } catch {
            return .failed(.unknown)
        }
    }

    /// Produces a stable, container-scoped value suitable only for selecting a
    /// local replica directory. The CloudKit record name is never displayed,
    /// logged, stored in an archive, or used across containers.
    public static func accountBinding(
        containerIdentifier: String,
        recordName: String
    ) -> String {
        let digest = SHA256.hash(data: Data(
            "keepsake-cloud-account\u{0}\(containerIdentifier)\u{0}\(recordName)".utf8
        ))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func issue(for error: CKError) -> SyncIssue {
        switch error.code {
        case .networkFailure, .networkUnavailable, .serviceUnavailable,
             .requestRateLimited, .zoneBusy:
            .network
        case .quotaExceeded:
            .quota
        case .notAuthenticated, .permissionFailure:
            .account
        default:
            .service
        }
    }
}
