import AppKit
import Observation
import Sparkle

/// Mises à jour automatiques via Sparkle : vérification quotidienne de l'appcast publié avec
/// chaque release GitHub (voir SUFeedURL dans Info.plist).
///
/// Amplo vit dans la barre des menus : une mise à jour trouvée en arrière-plan est signalée
/// discrètement dans le menu (« rappel discret » de Sparkle) plutôt que d'interrompre l'utilisateur.
@MainActor
@Observable
final class UpdateManager: NSObject {
    /// Version trouvée lors d'une vérification automatique, en attente d'attention.
    private(set) var availableVersion: String?

    @ObservationIgnored private var updaterController: SPUStandardUpdaterController!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate()
        updaterController.checkForUpdates(nil)
    }
}

extension UpdateManager: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if !state.userInitiated {
            availableVersion = update.displayVersionString
        }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
