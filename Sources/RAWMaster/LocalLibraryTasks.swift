import Foundation

struct LibrarySwitchActivity {
    let title: String
    var canPause = true
}

/// Some 032 commands can be awaiting SQLite or source verification before a worker exists.
/// Keep their accounting in the owning model so a switch can wait for them too.
@MainActor final class LocalLibraryTaskOperations {
    private var active = 0
    private var joins: [CheckedContinuation<Void, Never>] = []
    var isActive: Bool { active > 0 }

    func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        active += 1
        defer {
            active -= 1
            if active == 0 {
                let waiting = joins
                joins.removeAll()
                for join in waiting { join.resume() }
            }
        }
        return try await operation()
    }

    func join() async {
        guard active > 0 else { return }
        await withCheckedContinuation { joins.append($0) }
    }
}

extension AppModel {
    func quiesceLocalLibraryTasksForSwitch() async {
        async let intake: Void = pauseLibraryImportForSwitch()
        async let delivery: Void = stopWorkbenchPhotoDelivery()
        async let originals: Void = originalDelivery.stopAndJoin()
        async let workflow: Void = sceneWorkflowBatches.stopAndJoin()
        _ = await (intake, delivery, originals, workflow)
        await workbenchDeliveryOperations.join()
    }

    func reopenLocalLibraryTasksAfterCancelledSwitch() {
        sceneWorkflowBatches.reopenAdmission()
        originalDelivery.reopenAdmission()
    }
}
