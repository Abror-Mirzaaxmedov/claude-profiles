import AppKit
import Combine
import Darwin
import Foundation

struct ClaudeProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var accountLabel: String
    let createdAt: Date
    /// The default profile is the one macOS opens when Claude is started outside
    /// this launcher (Dock, Spotlight, claude:// links, Claude's own update relaunch).
    var isDefault: Bool

    init(id: UUID = UUID(), name: String, accountLabel: String = "", createdAt: Date = .now, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.accountLabel = accountLabel
        self.createdAt = createdAt
        self.isDefault = isDefault
    }

    private enum CodingKeys: String, CodingKey { case id, name, accountLabel, createdAt, isDefault }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        accountLabel = try container.decodeIfPresent(String.self, forKey: .accountLabel) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

/// State of `~/Library/Application Support/Claude`, the folder Claude uses when it is
/// started without `--user-data-dir`.
enum DefaultFolderStatus: Equatable {
    /// It is a link to the default profile: every launch outside the launcher opens that profile.
    case linked
    /// A real folder is there (a separate, unmanaged Claude sign-in). It is left untouched.
    case blockedByRealFolder
    /// The link could not be created or updated.
    case failed(String)
    /// Nothing to link yet (no profiles).
    case none
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published var selectedProfileID: ClaudeProfile.ID?
    @Published var errorMessage: String?
    @Published private(set) var defaultFolderStatus: DefaultFolderStatus = .none

    /// Main Claude process for each running profile, found by reading the real process arguments.
    @Published private(set) var runningPIDs: [UUID: pid_t] = [:]
    /// Claude instances whose data folder matches no profile (for example a stray default folder).
    @Published private(set) var unmanagedInstanceCount = 0

    private let fileManager = FileManager.default
    private let claudeURL = URL(fileURLWithPath: "/Applications/Claude.app")
    private let claudeBundleIdentifier = "com.anthropic.claudefordesktop"
    private var refreshTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    var isShowingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    var selectedProfile: ClaudeProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var defaultProfile: ClaudeProfile? {
        profiles.first(where: \.isDefault) ?? profiles.first
    }

    init() {
        load()
        normalizeDefaultFlag()
        syncDefaultFolderLink()
        refreshRunningInstances()
        startMonitoring()
    }

    // MARK: - Queries

    func dataDirectory(for profile: ClaudeProfile) -> URL {
        profilesDirectory.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
    }

    func isRunning(_ profile: ClaudeProfile) -> Bool {
        runningPIDs[profile.id] != nil
    }

    func isDefault(_ profile: ClaudeProfile) -> Bool {
        defaultProfile?.id == profile.id
    }

    /// Best-effort check: Claude keeps its encrypted OAuth token cache in config.json
    /// and removes it on sign-out.
    func isSignedIn(_ profile: ClaudeProfile) -> Bool {
        let configURL = dataDirectory(for: profile).appending(path: "config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return ["oauth:tokenCacheV2", "oauth:tokenCache"].contains { key in
            guard let value = json[key] as? String else { return false }
            return !value.isEmpty
        }
    }

    func otherRunningProfiles(than profile: ClaudeProfile) -> [ClaudeProfile] {
        profiles.filter { $0.id != profile.id && isRunning($0) }
    }

    // MARK: - Editing

    func add(name: String, accountLabel: String) {
        let profile = ClaudeProfile(name: name.trimmed, accountLabel: accountLabel.trimmed, isDefault: profiles.isEmpty)
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
        syncDefaultFolderLink()
    }

    func update(_ profile: ClaudeProfile, name: String, accountLabel: String) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index].name = name.trimmed
        profiles[index].accountLabel = accountLabel.trimmed
        save()
    }

    func makeDefault(_ profile: ClaudeProfile) {
        guard !isDefault(profile) else { return }
        if defaultFolderInUse {
            showError("Quit the Claude window that was opened from the Dock or Spotlight first, then make \"\(profile.name)\" the default.")
            return
        }
        for index in profiles.indices {
            profiles[index].isDefault = profiles[index].id == profile.id
        }
        save()
        syncDefaultFolderLink()
    }

    func duplicate(_ profile: ClaudeProfile) {
        guard !isRunning(profile) else {
            showError("Stop the profile before duplicating it so its local data is copied consistently.")
            return
        }

        let copy = ClaudeProfile(name: "\(profile.name) Copy", accountLabel: profile.accountLabel)
        let source = dataDirectory(for: profile)
        let destination = dataDirectory(for: copy)
        do {
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: destination)
                removeChromiumLocks(in: destination)
            }
            profiles.append(copy)
            selectedProfileID = copy.id
            save()
        } catch {
            try? fileManager.removeItem(at: destination)
            showError("Couldn’t duplicate \"\(profile.name)\": \(error.localizedDescription)")
        }
    }

    func moveToTrash(_ profile: ClaudeProfile) {
        guard !isRunning(profile) else {
            showError("Stop the profile before moving it to Trash.")
            return
        }
        do {
            let wasDefault = isDefault(profile)
            if wasDefault { removeDefaultFolderLinkIfOurs() }
            let directory = dataDirectory(for: profile)
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.trashItem(at: directory, resultingItemURL: nil)
            }
            profiles.removeAll { $0.id == profile.id }
            if wasDefault, !profiles.isEmpty { profiles[0].isDefault = true }
            if selectedProfileID == profile.id { selectedProfileID = profiles.first?.id }
            save()
            syncDefaultFolderLink()
        } catch {
            showError("Couldn’t move \"\(profile.name)\" to Trash: \(error.localizedDescription)")
        }
    }

    // MARK: - Launching

    func launch(_ profile: ClaudeProfile) {
        refreshRunningInstances()
        if let pid = runningPIDs[profile.id], let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return
        }
        guard fileManager.fileExists(atPath: claudeURL.path) else {
            showError("Claude Desktop wasn’t found in /Applications/Claude.app.")
            return
        }

        let directory = dataDirectory(for: profile)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            showError("Couldn’t prepare the profile folder: \(error.localizedDescription)")
            return
        }
        if isDefault(profile) { syncDefaultFolderLink() }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = true
        configuration.arguments = ["--user-data-dir=\(directory.path)"]
        NSWorkspace.shared.openApplication(at: claudeURL, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                if let error {
                    self?.showError("Couldn’t launch Claude: \(error.localizedDescription)")
                }
                self?.refreshRunningInstances()
            }
        }
    }

    func stop(_ profile: ClaudeProfile) {
        guard let pid = runningPIDs[profile.id], let app = NSRunningApplication(processIdentifier: pid) else { return }
        if !app.terminate() {
            _ = app.forceTerminate()
        }
    }

    func stop(_ profiles: [ClaudeProfile], then completion: @escaping @MainActor () -> Void) {
        profiles.forEach(stop)
        waitUntilStopped(profiles.map(\.id), attemptsRemaining: 40, completion: completion)
    }

    private func waitUntilStopped(_ ids: [UUID], attemptsRemaining: Int, completion: @escaping @MainActor () -> Void) {
        refreshRunningInstances()
        if ids.allSatisfy({ runningPIDs[$0] == nil }) || attemptsRemaining == 0 {
            completion()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.waitUntilStopped(ids, attemptsRemaining: attemptsRemaining - 1, completion: completion)
        }
    }

    // MARK: - Running-instance detection

    /// Reads the actual `--user-data-dir` of every running Claude instance, so the status stays
    /// correct after Claude relaunches itself (updates, crashes) or this launcher restarts.
    func refreshRunningInstances() {
        let defaultPath = canonicalPath(defaultClaudeDataDirectory)
        var byPath: [String: UUID] = [:]
        for profile in profiles {
            byPath[canonicalPath(dataDirectory(for: profile))] = profile.id
        }

        var found: [UUID: pid_t] = [:]
        var unmanaged = 0
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleIdentifier) where !app.isTerminated {
            let pid = app.processIdentifier
            let dataDir = processArguments(pid: pid).flatMap(userDataDirectory(in:))
            let path = dataDir.map { canonicalPath(URL(fileURLWithPath: $0)) } ?? defaultPath
            if let id = byPath[path] {
                found[id] = found[id] ?? pid
            } else {
                unmanaged += 1
            }
        }
        if found != runningPIDs { runningPIDs = found }
        if unmanaged != unmanagedInstanceCount { unmanagedInstanceCount = unmanaged }
    }

    /// True when a Claude instance was started without `--user-data-dir` (through the link).
    private var defaultFolderInUse: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleIdentifier).contains { app in
            !app.isTerminated && processArguments(pid: app.processIdentifier).flatMap(userDataDirectory(in:)) == nil
        }
    }

    private func startMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshRunningInstances() }
            })
        }
        // Claude can take a moment to register; a slow poll also catches self-relaunches.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshRunningInstances() }
        }
    }

    private func userDataDirectory(in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("--user-data-dir=") {
                return String(argument.dropFirst("--user-data-dir=".count))
            }
            if argument == "--user-data-dir", index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    /// Exact argv of a process via KERN_PROCARGS2 (paths with spaces survive intact, unlike `ps`).
    private func processArguments(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }

        let argc = buffer.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 } // executable path
        while index < size, buffer[index] == 0 { index += 1 } // padding

        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private func canonicalPath(_ url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: - Default Claude folder link

    /// The folder Claude uses when started without arguments.
    private var defaultClaudeDataDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Claude", directoryHint: .isDirectory)
    }

    /// Points `~/Library/Application Support/Claude` at the default profile. Without this, every
    /// Claude start that bypasses the launcher (Dock icon, Spotlight, a claude:// sign-in link
    /// while Claude is closed, Claude's own relaunch after an update) opens an empty folder and
    /// asks to sign in again. A real folder there is never touched.
    func syncDefaultFolderLink() {
        guard let profile = defaultProfile else {
            defaultFolderStatus = .none
            return
        }
        let link = defaultClaudeDataDirectory
        let target = dataDirectory(for: profile)
        do {
            try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
                if canonicalPath(URL(fileURLWithPath: destination)) == canonicalPath(target) {
                    defaultFolderStatus = .linked
                    return
                }
                guard !defaultFolderInUse else {
                    defaultFolderStatus = .failed("Claude is running from the old default folder. Quit it and reopen Claude Profiles.")
                    return
                }
                try fileManager.removeItem(atPath: link.path)
            } else if fileManager.fileExists(atPath: link.path) {
                defaultFolderStatus = .blockedByRealFolder
                return
            }
            try fileManager.createSymbolicLink(at: link, withDestinationURL: target)
            defaultFolderStatus = .linked
        } catch {
            defaultFolderStatus = .failed(error.localizedDescription)
        }
    }

    private func removeDefaultFolderLinkIfOurs() {
        let link = defaultClaudeDataDirectory
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path),
              canonicalPath(URL(fileURLWithPath: destination)).hasPrefix(canonicalPath(profilesDirectory)) else { return }
        try? fileManager.removeItem(atPath: link.path)
    }

    // MARK: - Persistence

    private var applicationSupportDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ClaudeProfiles", directoryHint: .isDirectory)
    }

    private var profilesDirectory: URL {
        applicationSupportDirectory.appending(path: "Profiles", directoryHint: .isDirectory)
    }

    private var registryURL: URL {
        applicationSupportDirectory.appending(path: "profiles.json")
    }

    private func normalizeDefaultFlag() {
        guard !profiles.isEmpty else { return }
        let defaultID = defaultProfile?.id
        let needsSave = profiles.filter(\.isDefault).count != 1
        for index in profiles.indices {
            profiles[index].isDefault = profiles[index].id == defaultID
        }
        if needsSave { save() }
    }

    private func load() {
        do {
            try fileManager.createDirectory(at: profilesDirectory, withIntermediateDirectories: true)
            guard fileManager.fileExists(atPath: registryURL.path) else { return }
            profiles = try JSONDecoder().decode([ClaudeProfile].self, from: Data(contentsOf: registryURL))
            selectedProfileID = profiles.first?.id
        } catch {
            showError("Couldn’t load the local profile registry: \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(profiles).write(to: registryURL, options: .atomic)
        } catch {
            showError("Couldn’t save the local profile registry: \(error.localizedDescription)")
        }
    }

    private func removeChromiumLocks(in directory: URL) {
        for filename in ["SingletonCookie", "SingletonLock", "SingletonSocket"] {
            try? fileManager.removeItem(at: directory.appending(path: filename))
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
