import SwiftUI
import UniformTypeIdentifiers

/// Drill-down page for local profiles and on-device data (backups, OPML,
/// encrypted backups, clear-all). Owns every `.fileExporter` / `.fileImporter` /
/// backup-alert that used to be bolted onto the root Settings Form, plus the
/// encrypted-backup password sheet and the profile create/rename sheet, so the
/// root's presentation surface is just its own consolidated `.sheet(item:)`.
struct DataProfilesSettingsView: View {
    @ObservedObject var db: LocalDB
    @ObservedObject var theme: ThemeManager
    @ObservedObject var i18n: I18nManager
    @ObservedObject var appearance: AppearanceManager
    @StateObject private var profiles = LocalProfileStore.shared

    private enum ProfileSheetRequest: Identifiable, Equatable {
        case create
        case rename(UUID)

        var id: String {
            switch self {
            case .create: return "create"
            case .rename(let uuid): return "rename-\(uuid.uuidString)"
            }
        }

        var mode: ProfileNameMode {
            switch self {
            case .create: return .create
            case .rename: return .rename
            }
        }

        var renameTarget: UUID? {
            switch self {
            case .create: return nil
            case .rename(let uuid): return uuid
            }
        }
    }

    @State private var profileSheet: ProfileSheetRequest?
    @State private var showingClearAllAlert = false
    @State private var backupDocument = LocalBackupDocument()
    @State private var showingBackupExporter = false
    @State private var showingBackupImporter = false
    @State private var diagnosticsDocument = LocalBackupDocument()
    @State private var showingDiagnosticsExporter = false
    @State private var opmlDocument = OPMLDocument()
    @State private var showingOPMLExporter = false
    @State private var encryptedBackupDocument = EncryptedBackupDocument()
    @State private var showingEncryptedBackupExporter = false
    @State private var showingEncryptedBackupImporter = false
    @State private var encryptedBackupOperation: EncryptedBackupOperation?
    @State private var isSubmittingEncryptedBackup = false
    @State private var encryptedBackupTask: Task<Void, Never>?
    @State private var encryptedBackupPassword = ""
    @State private var encryptedBackupConfirmation = ""
    @State private var encryptedBackupError = ""
    @State private var pendingEncryptedBackupData: Data?
    @State private var backupMessage = ""
    @State private var showingBackupMessage = false
    @State private var profileTransferDocument = LocalProfileTransferDocument()
    @State private var showingProfileExporter = false
    @State private var showingProfileImporter = false
    @State private var profileName = ""
    @State private var profileError = ""
    @State private var isProfileSectionExpanded = SettingsEnvironment.isUITesting
    @State private var isDataSectionExpanded = SettingsEnvironment.isUITesting

    private var isProfileNameSheetActive: Bool { profileSheet != nil }

    var body: some View {
        Form {
            localStorageSection
        }
        .font(appearance.font(size: 13))
        .background(theme.colors.bg)
        .navigationTitle(i18n.t("dataAndProfilesSection"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("settings.dataProfilesScreen")
        .alert(i18n.t("clearAllDataAlert"), isPresented: $showingClearAllAlert) {
            Button(i18n.t("cancel"), role: .cancel) {}
            Button(i18n.t("delete"), role: .destructive) {
                db.clearAllData()
            }
        } message: {
            Text(i18n.t("clearAllDataMessage"))
        }
        .sheet(item: $profileSheet) { request in
            ProfileNameSheet(
                mode: request.mode,
                db: db,
                i18n: i18n,
                isPresented: Binding(
                    get: { profileSheet != nil },
                    set: { if !$0 { profileSheet = nil } }
                ),
                name: $profileName,
                errorText: $profileError,
                profileToRename: request.renameTarget,
                localizedError: localizedProfileMessage
            )
        }
        .sheet(item: $encryptedBackupOperation) { operation in
            EncryptedBackupPasswordSheet(
                operation: operation,
                password: $encryptedBackupPassword,
                confirmation: $encryptedBackupConfirmation,
                errorMessage: $encryptedBackupError,
                isSubmitting: isSubmittingEncryptedBackup,
                onCancel: cancelEncryptedBackupPrompt,
                onSubmit: submitEncryptedBackupPrompt
            )
            .interactiveDismissDisabled(isSubmittingEncryptedBackup)
            .presentationDetents([.medium])
        }
        // Swipe-to-dismiss sets encryptedBackupOperation directly,
        // bypassing cancelEncryptedBackupPrompt — catch that path too so
        // an in-flight submission can't outlive the dismissed sheet.
        .onChange(of: encryptedBackupOperation) { _, newValue in
            if newValue == nil {
                encryptedBackupTask?.cancel()
                isSubmittingEncryptedBackup = false
            }
        }
        .fileExporter(
            isPresented: $showingBackupExporter,
            document: backupDocument,
            contentType: .json,
            defaultFilename: "oshireader-backup.json"
        ) { result in
            if case .failure(let error) = result {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
            }
        }
        .fileExporter(
            isPresented: $showingDiagnosticsExporter,
            document: diagnosticsDocument,
            contentType: .json,
            defaultFilename: "oshireader-diagnostics.json"
        ) { result in
            if case .failure(let error) = result {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
            }
        }
        .fileExporter(
            isPresented: $showingOPMLExporter,
            document: opmlDocument,
            contentType: .opml,
            defaultFilename: "oshireader.opml"
        ) { result in
            if case .failure(let error) = result {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
            }
        }
        .fileImporter(isPresented: $showingBackupImporter, allowedContentTypes: [.json]) { result in
            let data: Data
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                guard let byteCount = fileByteCount(at: url),
                      byteCount <= Int64(LocalDB.maximumBackupBytes) else {
                    backupMessage = i18n.t("backupFileTooLarge")
                    showingBackupMessage = true
                    return
                }
                // Read eagerly (not mapped) so the buffer stays valid after
                // the security-scoped access ends and the decode/normalize
                // work can move off the main thread below.
                data = try Data(contentsOf: url)
            } catch {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
                return
            }
            Task {
                do {
                    try await db.importBackupDataOffMain(data)
                    backupMessage = i18n.t("backupImported")
                } catch {
                    backupMessage = localizedBackupMessage(error)
                }
                showingBackupMessage = true
            }
        }
        .fileExporter(
            isPresented: $showingEncryptedBackupExporter,
            document: encryptedBackupDocument,
            contentType: .oshiReaderEncryptedBackup,
            defaultFilename: "oshireader-backup.oshireader"
        ) { result in
            if case .failure(let error) = result {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
            }
        }
        .fileImporter(
            isPresented: $showingEncryptedBackupImporter,
            allowedContentTypes: [.oshiReaderEncryptedBackup, .data]
        ) { result in
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer {
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                guard let byteCount = fileByteCount(at: url),
                      byteCount <= Int64(EncryptedBackupCodec.maximumEnvelopeBytes) else {
                    throw EncryptedBackupError.payloadTooLarge
                }
                pendingEncryptedBackupData = try Data(contentsOf: url, options: [.mappedIfSafe])
                encryptedBackupPassword = ""
                encryptedBackupConfirmation = ""
                encryptedBackupError = ""
                encryptedBackupOperation = .import
            } catch {
                backupMessage = localizedBackupMessage(error)
                showingBackupMessage = true
            }
        }
        .alert(i18n.t("backupStatus"), isPresented: $showingBackupMessage) {
            Button(i18n.t("ok"), role: .cancel) {}
        } message: {
            Text(backupMessage)
        }
        .fileExporter(
            isPresented: $showingProfileExporter,
            document: profileTransferDocument,
            contentType: .oshiReaderProfile,
            defaultFilename: "oshireader-profile.oshireaderprofile"
        ) { result in
            if case .failure(let error) = result { profileError = localizedProfileMessage(error) }
        }
        .fileImporter(isPresented: $showingProfileImporter, allowedContentTypes: [.oshiReaderProfile, .data]) { result in
            let data: Data
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let byteCount = fileByteCount(at: url),
                      byteCount <= Int64(LocalDB.maximumProfileTransferBytes) else { throw LocalProfileError.invalidPackage }
                data = try Data(contentsOf: url)
            } catch {
                profileError = localizedProfileMessage(error)
                return
            }
            Task {
                do {
                    let imported = try await db.importProfileTransferData(data)
                    profileError = i18n.t("profileImported").replacingOccurrences(of: "%@", with: imported.name)
                } catch {
                    profileError = localizedProfileMessage(error)
                }
            }
        }
        .alert(i18n.t("profileStatus"), isPresented: Binding(
            get: { !profileError.isEmpty && !isProfileNameSheetActive },
            set: { if !$0 { profileError = "" } }
        )) {
            Button(i18n.t("ok"), role: .cancel) { profileError = "" }
        } message: { Text(profileError) }
    }

    private var activeProfileName: String {
        profiles.profiles.first { $0.id == profiles.activeProfileID }?.name ?? i18n.t("active")
    }

    private func beginEncryptedExport() {
        encryptedBackupPassword = ""
        encryptedBackupConfirmation = ""
        encryptedBackupError = ""
        encryptedBackupOperation = .export
    }

    private func cancelEncryptedBackupPrompt() {
        encryptedBackupTask?.cancel()
        // PBKDF2 itself can't be interrupted mid-derivation, so the
        // cancelled Task's own `defer` won't clear this until that
        // (now-orphaned, effect-free thanks to the isCancelled checks)
        // computation finally finishes. Reset it here instead, so
        // resubmitting right after cancelling isn't blocked by the
        // re-entry guard for however long that takes.
        isSubmittingEncryptedBackup = false
        encryptedBackupOperation = nil
        encryptedBackupPassword = ""
        encryptedBackupConfirmation = ""
        encryptedBackupError = ""
        pendingEncryptedBackupData = nil
    }

    private func submitEncryptedBackupPrompt() {
        // Making this async (to move PBKDF2 off the main thread) reopened a
        // double-tap window the old synchronous call implicitly closed by
        // freezing the UI — guard re-entry explicitly instead.
        guard !isSubmittingEncryptedBackup else { return }
        do {
            try EncryptedBackupCodec.validatePassword(encryptedBackupPassword)
        } catch {
            encryptedBackupError = localizedEncryptedBackupMessage(error)
            return
        }
        switch encryptedBackupOperation {
        case .export:
            guard encryptedBackupPassword == encryptedBackupConfirmation else {
                encryptedBackupError = i18n.t("passwordsDoNotMatch")
                return
            }
            let password = encryptedBackupPassword
            isSubmittingEncryptedBackup = true
            // exportEncryptedBackupData runs its PBKDF2 work off the main
            // thread; awaiting it here keeps this button tap from freezing
            // the UI for the duration of key derivation. Cancellation is
            // checked after the await since export doesn't mutate any
            // persisted state — there's nothing to undo, just UI to skip.
            encryptedBackupTask = Task {
                defer { isSubmittingEncryptedBackup = false }
                do {
                    let data = try await db.exportEncryptedBackupData(password: password)
                    guard !Task.isCancelled else { return }
                    encryptedBackupDocument = EncryptedBackupDocument(data: data)
                    encryptedBackupOperation = nil
                    encryptedBackupPassword = ""
                    encryptedBackupConfirmation = ""
                    // Deferred a tick so the sheet dismissal above (from
                    // clearing encryptedBackupOperation) settles before the
                    // file exporter presents — presenting immediately in the
                    // same update as a dismiss can silently no-op in SwiftUI.
                    DispatchQueue.main.async {
                        showingEncryptedBackupExporter = true
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    encryptedBackupError = localizedEncryptedBackupMessage(error)
                }
            }
        case .import:
            guard let data = pendingEncryptedBackupData else {
                encryptedBackupError = localizedEncryptedBackupMessage(EncryptedBackupError.invalidEnvelope)
                return
            }
            let password = encryptedBackupPassword
            isSubmittingEncryptedBackup = true
            encryptedBackupTask = Task {
                defer { isSubmittingEncryptedBackup = false }
                do {
                    // Unlike export, importBackupData mutates local data and
                    // can't be undone — decrypt (the slow PBKDF2 step) first,
                    // check for cancellation, and only then apply the import,
                    // instead of letting an already-cancelled request still
                    // overwrite the user's data.
                    let plaintext = try await Task.detached(priority: .userInitiated) {
                        try EncryptedBackupCodec.decrypt(data, password: password)
                    }.value
                    guard !Task.isCancelled else { return }
                    try await db.importBackupDataOffMain(plaintext)
                    encryptedBackupOperation = nil
                    encryptedBackupPassword = ""
                    pendingEncryptedBackupData = nil
                    backupMessage = i18n.t("backupImported")
                    showingBackupMessage = true
                } catch {
                    guard !Task.isCancelled else { return }
                    encryptedBackupError = localizedEncryptedBackupMessage(error)
                }
            }
        case nil:
            break
        }
    }

    private func localizedProfileMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "OshiReaderProfile", nsError.code == 5 {
            return i18n.t("profilePackageTooLarge")
        }
        guard let profileError = error as? LocalProfileError else { return error.localizedDescription }
        switch profileError {
        case .invalidName: return i18n.t("profileInvalidName")
        case .duplicateName: return i18n.t("profileDuplicateName")
        case .profileNotFound: return i18n.t("profileNotFound")
        case .cannotDeleteLastProfile: return i18n.t("cannotDeleteLastProfile")
        case .invalidPackage: return i18n.t("invalidProfilePackage")
        case .unsupportedPackageVersion: return i18n.t("unsupportedProfilePackageVersion")
        }
    }

    private func localizedEncryptedBackupMessage(_ error: Error) -> String {
        guard let backupError = error as? EncryptedBackupError else { return error.localizedDescription }
        switch backupError {
        case .invalidPassword: return i18n.t("encryptedBackupInvalidPassword")
        case .invalidEnvelope: return i18n.t("encryptedBackupInvalidEnvelope")
        case .unsupportedVersion: return i18n.t("encryptedBackupUnsupportedVersion")
        case .authenticationFailed: return i18n.t("encryptedBackupAuthenticationFailed")
        case .keyDerivationFailed: return i18n.t("encryptedBackupKeyDerivationFailed")
        case .payloadTooLarge: return i18n.t("encryptedBackupPayloadTooLarge")
        }
    }

    private func localizedBackupMessage(_ error: Error) -> String {
        if let backupError = error as? EncryptedBackupError {
            return localizedEncryptedBackupMessage(backupError)
        }
        let nsError = error as NSError
        guard nsError.domain == "OshiReaderBackup" else { return error.localizedDescription }
        switch nsError.code {
        case 2:
            return i18n.t("backupTooManyPlatforms")
        case 3:
            return i18n.t("backupRestoreStagingIncomplete")
        case 4:
            return i18n.t("backupTooMuchData")
        case 5:
            return i18n.t("backupFileTooLarge")
        case 6:
            if nsError.localizedDescription == "Invalid restore staging path" {
                return i18n.t("backupInvalidRestoreStagingPath")
            }
            return i18n.t("backupInvalidRestoreManifest")
        default:
            return error.localizedDescription
        }
    }

    /// Byte size of a security-scoped file, or `nil` when the OS won't report
    /// it. `FileManager.attributesOfItem(atPath:)` is unreliable for
    /// document-picker / iCloud URLs; the old `?? 0` fallback made every
    /// `<= max` guard pass on failure and `Data(contentsOf:)` then loaded the
    /// whole file. Callers must treat `nil` as a hard failure.
    private func fileByteCount(at url: URL) -> Int64? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
        return Int64(size)
    }

    private var localStorageSection: some View {
        Section {
            DisclosureGroup(isExpanded: $isProfileSectionExpanded) {
                ForEach(profiles.profiles) { profile in
                    HStack {
                        Button {
                            do {
                                try db.switchProfile(to: profile.id)
                            } catch {
                                profileError = localizedProfileMessage(error)
                            }
                        } label: {
                            HStack {
                                Image(systemName: profile.id == profiles.activeProfileID ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading) {
                                    Text(profile.name)
                                    if profile.id == profiles.activeProfileID {
                                        Text(i18n.t("active"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.profile.\(profile.id.uuidString)")

                        Spacer()

                        Button {
                            profileName = profile.name
                            profileError = ""
                            profileSheet = .rename(profile.id)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .accessibilityLabel(i18n.t("renameProfile"))
                        .accessibilityIdentifier("settings.profileRename.\(profile.id.uuidString)")

                        Button(role: .destructive) {
                            do {
                                try db.deleteProfile(id: profile.id)
                            } catch {
                                profileError = localizedProfileMessage(error)
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel(i18n.t("deleteProfile"))
                        .accessibilityIdentifier("settings.profileDelete.\(profile.id.uuidString)")
                    }
                }

                Button {
                    profileName = ""
                    profileError = ""
                    profileSheet = .create
                } label: {
                    Label(i18n.t("addProfile"), systemImage: "plus")
                }
                .accessibilityIdentifier("settings.addProfileButton")

                Button {
                    do {
                        profileTransferDocument = LocalProfileTransferDocument(data: try db.exportProfileTransferData())
                        showingProfileExporter = true
                    } catch {
                        profileError = localizedProfileMessage(error)
                    }
                } label: {
                    Label(i18n.t("exportProfile"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.exportProfileButton")

                Button {
                    showingProfileImporter = true
                } label: {
                    Label(i18n.t("importProfile"), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings.importProfileButton")

                Text(i18n.t("profilesFooter"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } label: {
                HStack {
                    Label(i18n.t("profiles"), systemImage: "person.crop.circle")
                    Spacer()
                    Text(activeProfileName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            DisclosureGroup(isExpanded: $isDataSectionExpanded) {
                Button {
                    do {
                        backupDocument = LocalBackupDocument(data: try db.exportBackupData())
                        showingBackupExporter = true
                    } catch {
                        backupMessage = localizedBackupMessage(error)
                        showingBackupMessage = true
                    }
                } label: {
                    Label(i18n.t("exportBackup"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("settings.exportBackupButton")

                Button {
                    if let data = RefreshDiagnostics.shared.exportHealthHistoryJSON() {
                        diagnosticsDocument = LocalBackupDocument(data: data)
                        showingDiagnosticsExporter = true
                    } else {
                        backupMessage = i18n.t("diagnosticsExportFailed")
                        showingBackupMessage = true
                    }
                } label: {
                    Label(i18n.t("exportDiagnostics"), systemImage: "stethoscope")
                }
                .accessibilityIdentifier("settings.exportDiagnosticsButton")

                Button {
                    opmlDocument = OPMLDocument(text: OPMLExporter.export(
                        terms: db.terms,
                        subscribedPlatforms: db.subscribedPlatforms,
                        customUrls: db.customUrls,
                        amebloBlogs: db.amebloBlogs,
                        generatedAt: Date()
                    ))
                    showingOPMLExporter = true
                } label: {
                    Label(i18n.t("exportOPML"), systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("settings.exportOPMLButton")

                Button {
                    showingBackupImporter = true
                } label: {
                    Label(i18n.t("importBackup"), systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("settings.importBackupButton")

                Button {
                    beginEncryptedExport()
                } label: {
                    Label(i18n.t("exportEncryptedBackup"), systemImage: "lock.square.stack")
                }
                .accessibilityIdentifier("settings.exportEncryptedBackupButton")

                Button {
                    showingEncryptedBackupImporter = true
                } label: {
                    Label(i18n.t("importEncryptedBackup"), systemImage: "lock.open")
                }
                .accessibilityIdentifier("settings.importEncryptedBackupButton")

                Button(role: .destructive) {
                    showingClearAllAlert = true
                } label: {
                    Label(i18n.t("clearAllData"), systemImage: "trash")
                }
                .accessibilityIdentifier("settings.clearAllDataButton")
            } label: {
                Label(i18n.t("dataSection"), systemImage: "externaldrive")
            }
        }
    }
}

struct ProfileNameSheet: View {
    let mode: ProfileNameMode
    @ObservedObject var db: LocalDB
    @ObservedObject var i18n: I18nManager
    @Binding var isPresented: Bool
    @Binding var name: String
    @Binding var errorText: String
    let profileToRename: UUID?
    let localizedError: (Error) -> String

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .create ? i18n.t("addProfile") : i18n.t("renameProfile"))
                .font(.headline)
            TextField(i18n.t("profileName"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.profileNameField")
            if !errorText.isEmpty { Text(errorText).foregroundStyle(.red).font(.caption) }
            HStack {
                Button(i18n.t("cancel")) { isPresented = false }
                    .accessibilityIdentifier("settings.profileCancelButton")
                Button(i18n.t("save")) {
                    do {
                        switch mode {
                        case .create: _ = try db.createProfile(name: name)
                        case .rename:
                            guard let profileToRename else { throw LocalProfileError.profileNotFound }
                            try db.renameProfile(id: profileToRename, name: name)
                        }
                        isPresented = false
                        errorText = ""
                    } catch { errorText = localizedError(error) }
                }
                .accessibilityIdentifier("settings.profileSaveButton")
            }
        }
        .padding()
        .presentationDetents([.medium])
    }
}

struct EncryptedBackupPasswordSheet: View {
    let operation: EncryptedBackupOperation
    @Binding var password: String
    @Binding var confirmation: String
    @Binding var errorMessage: String
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @StateObject private var i18n = I18nManager.shared

    private var isExport: Bool { operation == .export }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(i18n.t("password"), text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("settings.encryptedBackupPasswordField")

                    if isExport {
                        SecureField(i18n.t("confirmPassword"), text: $confirmation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings.encryptedBackupConfirmationField")
                    }
                } footer: {
                    Text(isExport
                         ? i18n.t("encryptedBackupExportPasswordHint")
                         : i18n.t("encryptedBackupImportPasswordHint"))
                }

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.footnote)
                        .accessibilityIdentifier("settings.encryptedBackupError")
                }

                Section {
                    Button {
                        onSubmit()
                    } label: {
                        if isSubmitting {
                            HStack {
                                ProgressView()
                                Text(isExport ? i18n.t("exportEncryptedBackup") : i18n.t("importEncryptedBackup"))
                            }
                        } else {
                            Text(isExport ? i18n.t("exportEncryptedBackup") : i18n.t("importEncryptedBackup"))
                        }
                    }
                    .disabled(isSubmitting)
                    .accessibilityIdentifier("settings.encryptedBackupSubmitButton")
                    Button(i18n.t("cancel"), role: .cancel, action: onCancel)
                        .accessibilityIdentifier("settings.encryptedBackupCancelButton")
                }
            }
            .navigationTitle(isExport ? i18n.t("encryptedBackupTitle") : i18n.t("unlockBackup"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
