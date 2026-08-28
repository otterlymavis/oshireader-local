import SwiftUI
import UniformTypeIdentifiers

struct LocalBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct EncryptedBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.oshiReaderEncryptedBackup, .data] }
    static var writableContentTypes: [UTType] { [.oshiReaderEncryptedBackup] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LocalProfileTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.oshiReaderProfile, .data] }
    static var writableContentTypes: [UTType] { [.oshiReaderProfile] }

    var data: Data

    init(data: Data = Data()) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum EncryptedBackupOperation: String, Identifiable {
    case export
    case `import`

    var id: String { rawValue }
}

enum ProfileNameMode: Equatable {
    case create
    case rename
}

/// The modal sheets `SettingsView`'s root Form presents. Consolidated into a
/// single `.sheet(item:)` — stacking several `.sheet(isPresented:)` on the Form
/// (alongside its `.alert` / `.fileImporter` / `.fileExporter`) made an earlier
/// one intermittently fail to present after an unrelated re-render.
enum SettingsSheet: Identifiable, Equatable {
    case addKeyword
    case platformSubscription

    var id: String {
        switch self {
        case .addKeyword: return "addKeyword"
        case .platformSubscription: return "platformSubscription"
        }
    }
}

/// Evaluated once per process instead of at each `@State` initializer that used
/// to re-scan `ProcessInfo.processInfo.arguments`.
enum SettingsEnvironment {
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
}
