import Foundation

enum PendingDelivery {
    /// The persisted batch is the source of truth until both delivery and checkpoint persistence succeed.
    @MainActor
    static func deliver(
        _ state: SyncState,
        upload: (SyncBatch) async throws -> Void,
        persist: (SyncState) throws -> Void
    ) async throws -> SyncState {
        guard let pending = state.pending else { return state }
        try Task.checkCancellation()
        if pending.recordCount > 0 { try await upload(pending) }
        var next = state
        next.commitPending()
        try persist(next)
        return next
    }
}
