import ResoniqDesign
import ResoniqStore
import SwiftData
import SwiftUI

/// The store, the session memory, the three coordinators and the lifecycle hook, made once at launch and put in the environment.
struct AppComposition {
    let store: ResoniqStore
    let memory: ComparisonMemory
    let coordinator: DiagnoseCoordinator
    let measure: MeasureCoordinator
    let optimize: OptimizeCoordinator
    let lifecycle: AppLifecycle

    /// Opens the store (on disk, or in memory when `inMemory`), makes sure "My room · My speakers" exists, and wires
    /// the coordinator. Nil when the store cannot be opened.
    ///
    /// Debug builds read launch arguments: `-inMemoryStore YES` starts with nothing stored, and `-screen app-flow`
    /// does the same on simulated audio, already inside the flow for the left speaker.
    static func launch(
        inMemory: Bool = false, audio: AudioEnvironment = .current, optimizeSources: OptimizeSources = .live
    ) -> AppComposition? {
        var inMemory = inMemory
        var audio = audio
        var opensFlow = false
        #if DEBUG
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "inMemoryStore") { inMemory = true }
        if defaults.string(forKey: "screen") == "app-flow" {
            inMemory = true
            audio = .simulated(noise: defaults.bool(forKey: "simulatedNoise"))
            opensFlow = true
        }
        #endif

        // Room scans are kept on the phone in Application Support; an in-memory store keeps no files.
        let scanFiles = inMemory ? nil : try? ScanFileStore.applicationSupport()
        guard let store = try? ResoniqStore(inMemory: inMemory, scanFiles: scanFiles), (try? store.defaultContext()) != nil else {
            return nil
        }
        let memory = ComparisonMemory()
        let coordinator = DiagnoseCoordinator(store: store, memory: memory, audio: audio)
        if opensFlow { coordinator.startTest(.left) }
        let measure = MeasureCoordinator(store: store, audio: audio)
        let optimize = OptimizeCoordinator(store: store, measure: measure, sources: optimizeSources)

        // When the scene leaves the foreground, a running test or measurement is cancelled and the live stream
        // stops. Diagnose's flow is cancelled in place (a result on screen stays); this does not touch its files.
        let lifecycle = AppLifecycle()
        lifecycle.onLeavingForeground { [coordinator] in
            if case .test(let flow) = coordinator.content { flow.cancel() }
        }
        lifecycle.onLeavingForeground { [measure] in measure.suspend() }
        // The scan and the AR guide close their covers, which stops the camera and the AR session.
        lifecycle.onLeavingForeground { [optimize] in optimize.suspend() }
        return AppComposition(
            store: store, memory: memory, coordinator: coordinator, measure: measure, optimize: optimize,
            lifecycle: lifecycle)
    }
}

extension EnvironmentValues {
    /// The app's store, for views that need more than `@Query` gives them. Nil only in previews that skip it.
    @Entry var resoniqStore: ResoniqStore?
}

extension View {
    /// The model container, the store, the session memory and the Diagnose coordinator.
    func appEnvironment(_ composition: AppComposition) -> some View {
        self
            .modelContainer(composition.store.container)
            .environment(\.resoniqStore, composition.store)
            .environment(composition.memory)
            .environment(composition.coordinator)
            .environment(composition.measure)
            .environment(composition.optimize)
            .environment(\.appLifecycle, composition.lifecycle)
    }
}

/// Shown when the store cannot be opened, in place of the app.
struct StoreUnavailableScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ResoniqSpace.s3) {
            Text("I can't open your saved results.")
                .resoniqTitle(.medium)
                .accessibilityAddTraits(.isHeader)
            Text("Everything stays on this phone, and right now I can't read it. Close Resoniq and open it again. If this keeps happening, free up some space on the phone.")
                .font(ResoniqFont.body)
                .foregroundStyle(ResoniqColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ResoniqSpace.screenInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(ResoniqColor.ink)
    }
}

#Preview("Store unavailable") {
    StoreUnavailableScreen()
        .preferredColorScheme(.dark)
}
