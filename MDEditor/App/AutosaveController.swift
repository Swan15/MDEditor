import Foundation
import Observation

/// Idle autosave: ~1.5 s after the last edit, a dirty document that has a
/// file on disk is written silently. Never prompts, never saves untitled
/// documents. The toggle lives in `AppSettings` (default ON).
///
/// Edits are observed through `DocumentModel.isDirty` (the editor sets it on
/// every mutation); every change resets the idle timer, so a save fires only
/// once typing pauses.
@MainActor
final class AutosaveController {
    /// Idle delay before a save fires (injectable for tests).
    private var delay: Duration = .milliseconds(1500)

    private var document: DocumentModel?
    private var settings: AppSettings?
    private var save: (() -> Void)?
    private var pendingSave: Task<Void, Never>?
    private var isObserving = false

    deinit {
        pendingSave?.cancel()
    }

    /// Wires the controller to a document + settings and starts observing.
    /// Re-configuring keeps the single running observation.
    func configure(
        document: DocumentModel,
        settings: AppSettings,
        delay: Duration? = nil,
        save: @escaping () -> Void
    ) {
        self.document = document
        self.settings = settings
        if let delay { self.delay = delay }
        self.save = save
        guard !isObserving else { return }
        isObserving = true
        observeDirtyFlag(of: document)
    }

    /// Re-registers on every change: each edit (and each clean-mark) resets
    /// the idle timer, then re-arms the one-shot observation.
    private func observeDirtyFlag(of document: DocumentModel) {
        withObservationTracking {
            _ = document.isDirty
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, let document = self.document else { return }
                self.pendingSave?.cancel()
                self.pendingSave = nil
                self.scheduleSaveIfNeeded()
                self.observeDirtyFlag(of: document)
            }
        }
    }

    /// Arms the idle save when the policy allows it right now.
    private func scheduleSaveIfNeeded() {
        guard let document, let settings,
              DocumentSwitchPolicy.shouldAutosave(
                  isDirty: document.isDirty,
                  hasFileURL: document.fileURL != nil,
                  autosaveEnabled: settings.autosaveEnabled
              ) else { return }
        let delay = self.delay
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, let document = self.document, let settings = self.settings else { return }
            // Re-check at fire time: the document may have been saved,
            // switched or closed while the timer ran.
            guard DocumentSwitchPolicy.shouldAutosave(
                isDirty: document.isDirty,
                hasFileURL: document.fileURL != nil,
                autosaveEnabled: settings.autosaveEnabled
            ) else { return }
            self.save?()
        }
    }
}
