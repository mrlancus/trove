#if os(iOS)
import BackgroundTasks
import Foundation

/// iPhone/iPad background work:
///  - `refresh`: opportunistic sync (pull new items) a few times a day.
///  - `enrich`: a processing task that requires external power, so the iPad (Apple Intelligence)
///    catches up on everything saved elsewhere overnight while charging. The on-device model isn't
///    rate-limited on power, but is in the background on battery (RESEARCH.md §11).
enum BackgroundTasks {
    static let refreshID = "com.mrlancus.trove.refresh"
    static let enrichID = "com.mrlancus.trove.enrich"

    @MainActor
    static func register(model: AppModel) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { bgTask in
            nonisolated(unsafe) let task = bgTask
            let work = Task { @MainActor in
                await model.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
            scheduleRefresh()
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: enrichID, using: nil) { bgTask in
            nonisolated(unsafe) let task = bgTask
            let work = Task { @MainActor in
                await model.syncNow()
                await model.enrichOvernight()
                await model.syncNow()
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
            scheduleEnrichment()
        }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshID)
        request.earliestBeginDate = Date().addingTimeInterval(30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func scheduleEnrichment() {
        guard OnDeviceAI.isAvailable else { return }
        let request = BGProcessingTaskRequest(identifier: enrichID)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
#endif
