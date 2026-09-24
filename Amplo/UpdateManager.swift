import AppKit
import Observation
import Sparkle

/// Mises à jour automatiques via Sparkle.
///
/// Amplo vérifie chaque jour l'appcast publié avec chaque release GitHub (voir `SUFeedURL`
/// dans Info.plist). Amplo vit dans la barre des menus : une mise à jour trouvée en arrière-plan
/// est signalée discrètement dans le menu (« rappel discret » de Sparkle) plutôt que
/// d'interrompre l'utilisateur.
@MainActor
@Observable
final class UpdateManager {
    /// Version trouvée lors d'une vérification automatique, en attente d'attention.
    private(set) var availableVersion: String?

    @ObservationIgnored private let reminder = UpdateReminder()
    @ObservationIgnored private let updaterController: SPUStandardUpdaterController

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: reminder,
        )
        reminder.onAvailableVersionChange = { [weak self] version in
            self?.availableVersion = version
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        updaterController.checkForUpdates(nil)
    }
}

/// Délégué de Sparkle qui relaie les mises à jour trouvées en arrière-plan.
///
/// Sparkle ne garde qu'une référence faible vers son délégué : `UpdateManager` le conserve.
@MainActor
private final class UpdateReminder: NSObject {
    var onAvailableVersionChange: ((String?) -> Void)?
}

extension UpdateReminder: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState,
    ) {
        if !state.userInitiated {
            onAvailableVersionChange?(update.displayVersionString)
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        onAvailableVersionChange?(nil)
    }

    func standardUserDriverWillFinishUpdateSession() {
        onAvailableVersionChange?(nil)
    }
}
