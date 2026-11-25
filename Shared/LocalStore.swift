import Darwin
import Foundation

enum LocalError: Error { case storage, unavailable, signedOut, invalid, busy, notReady, expired, wrongAccount, permission, stale }

enum LocalStore {
    static let group = "group.com.hgsldswk.solocheckin"

    static func read() async throws -> CheckInState {
        try await Task.detached(priority: .userInitiated) {
            try locked(write: false) { $0 }.0
        }.value
    }

    static func update<T: Sendable>(_ body: @escaping @Sendable (inout CheckInState) throws -> T) async throws -> (CheckInState, T) {
        try await Task.detached(priority: .userInitiated) {
            try locked(write: true, body)
        }.value
    }

    private static func locked<T>(write: Bool, _ body: (inout CheckInState) throws -> T) throws -> (CheckInState, T) {
        let fm = FileManager.default
        let root: URL
        if Launch.testing {
            root = fm.temporaryDirectory.appendingPathComponent("SoloCheckInUITests")
        } else {
            #if targetEnvironment(simulator)
            root = fm.containerURL(forSecurityApplicationGroupIdentifier: group)
                ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            #else
            guard let group = fm.containerURL(forSecurityApplicationGroupIdentifier: group) else { throw LocalError.storage }
            root = group
            #endif
        }
        var directory = root.appendingPathComponent("SoloCheckIn", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var backup = URLResourceValues()
        backup.isExcludedFromBackup = true
        try? directory.setResourceValues(backup)
        let lock = directory.appendingPathComponent("store.lock")
        let file = directory.appendingPathComponent("state.json")
        let descriptor = open(lock.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw LocalError.storage }
        defer { close(descriptor) }
        guard flock(descriptor, write ? LOCK_EX : LOCK_SH) == 0 else { throw LocalError.storage }
        defer { flock(descriptor, LOCK_UN) }
        var state: CheckInState
        do {
            state = try JSONDecoder().decode(CheckInState.self, from: Data(contentsOf: file))
        } catch let failure as CocoaError where failure.code == .fileReadNoSuchFile {
            state = CheckInState()
        }
        let result = try body(&state)
        if write {
            try JSONEncoder().encode(state).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return (state, result)
    }
}
