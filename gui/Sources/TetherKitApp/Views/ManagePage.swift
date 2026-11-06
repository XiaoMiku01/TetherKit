import SwiftUI
import TetherKitIPC

/// The "Manage" page: privileged helper status and maintenance actions.
///
/// All of it used to be a caption footer squeezed at the bottom of the
/// old layout's left column. As a page it finally has room to say what
/// it maintains. Logic and `AppModel` interaction are unchanged:
/// installs/updates go through `installHelper()`, and the confirmation
/// rules still hold (updating while a session runs asks first).
struct ManagePage: View {
    @Bindable var model: AppModel

    /// Uninstall is destructive (disconnects, removes system files),
    /// so it asks first. 
    @State private var confirmingHelperUninstall = false

    /// Only an update that would hit a RUNNING session needs
    /// confirmation. The install scripts bootout the old component
    /// first, which cuts the connection. Updating while idle breaks
    /// nothing, and one more gate would only slow down something that
    /// should be quick.
    @State private var confirmingHelperUpdate = false

    var body: some View {
        Card(title: L(.manageHelperSectionTitle), systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: Design.Spacing.medium) {
                stateRows
                Divider()
                uninstallRow
            }
        }
        .confirmationDialog(L(.confirmUninstallTitle), isPresented: $confirmingHelperUninstall) {
            Button(L(.uninstall), role: .destructive) {
                Task { await model.uninstallHelper() }
            }
            Button(L(.cancel), role: .cancel) {}
        } message: {
            Text(uninstallWarning)
        }
        .confirmationDialog(L(.confirmHelperUpdateTitle), isPresented: $confirmingHelperUpdate) {
            Button(L(.updateHelperButton)) {
                Task { await model.installHelper() }
            }
            Button(L(.cancel), role: .cancel) {}
        } message: {
            Text(L(.helperUpdateWhileRunningWarning))
        }
    }

    private var uninstallWarning: String {
        let base = L(.uninstallExplanation)
        return model.status.runState == .running
            ? L(.uninstallWhileRunningWarning) + base
            : base
    }

    /// Helper version and the update entry. On a version mismatch this
    /// block turns from reference info into "there is a task waiting":
    /// both version numbers show side by side, and the color steps up
    /// from tertiary to orange.
    @ViewBuilder
    private var stateRows: some View {
        if case .available(let version) = model.helperAvailability {
            if let mismatch = model.helperVersionMismatch {
                HStack(alignment: .center, spacing: Design.Spacing.small) {
                    Text(L(.helperVersionMismatch, mismatch.installed, mismatch.expected))
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Design.Spacing.small)
                    // While busy, swap the label to "installing instead
                    // of just graying out the button: after the
                    // authorization dialog closes, the wait is several
                    // seconds (bootout, copy, bootstrap, liveness probe).
                    // A gray button looks like a tap that did nothing.
                    Button(model.isBusy ? L(.installingProgress) : L(.updateHelperButton)) {
                        requestHelperUpdate()
                    }
                    .disabled(model.isBusy)
                    .help(L(.helperVersionMismatchTooltip, mismatch.installed, mismatch.expected))
                }
            } else {
                HStack(alignment: .center, spacing: Design.Spacing.small) {
                    Text(L(.helperComponentVersion, version))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: Design.Spacing.small)
                    if let update = model.availableUpdate {
                        // Versions match but a newer Release exists on
                        // GitHub. Upgrading means typing brew in a
                        // terminal, so this badge is informational only.
                        // Mutually exclusive with the mismatch banner:
                        // a mismatch is a one-tap fix that should take
                        // the foreground. The update badge yields.
                        Button(L(.helperUpdateBadge, update.version)) {
                            model.updateCheckResult = .updateAvailable(update)
                        }
                        .font(.callout)
                    }
                }
            }
        }
    }

    /// Uninstall entry. A rare admin action: quiet, but present.
    /// Without it the helper would be "installable but unremovable"
    /// and users would dig for scripts in a terminal.
    private var uninstallRow: some View {
        HStack(alignment: .center, spacing: Design.Spacing.small) {
            Text(L(.uninstallExplanation))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Spacing.small)
            Button(L(.uninstallHelperMenuItem)) { confirmingHelperUninstall = true }
                .disabled(model.isBusy)
        }
    }

    /// "Update privileged helper" tapped. Confirms only while a session
    /// is running: see `confirmingHelperUpdate`.
    private func requestHelperUpdate() {
        if model.status.runState == .running {
            confirmingHelperUpdate = true
        } else {
            Task { await model.installHelper() }
        }
    }
}
