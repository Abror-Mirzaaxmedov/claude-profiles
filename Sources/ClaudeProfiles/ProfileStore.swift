import AppKit
import Combine
import Foundation

struct ClaudeProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var accountLabel: String
    let createdAt: Date

    init(id: UUID = UUID(), name: String, accountLabel: String = "", createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.accountLabel = accountLabel
        self.createdAt = createdAt
    }
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published var selectedProfileID: ClaudeProfile.ID?
    @Published var errorMessage: String?

    private var runningApps: [UUID: NSRunningApplication] = [:]
    private var launchProcesses: [UUID: Process] = [:]
    private let fileManager = FileManager.default
    private let claudeURL = URL(fileURLWithPath: "/Applications/Claude.app")
    private let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    var isShowingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    var selectedProfile: ClaudeProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    init() {
        load()
    }

    func dataDirectory(for profile: ClaudeProfile) -> URL {
        profilesDirectory.appending(path: profile.id.uuidString, directoryHint: .isDirectory)
    }

    func isRunning(_ profile: ClaudeProfile) -> Bool {
        guard let app = runningApps[profile.id] else { return false }
        return !app.isTerminated
    }

    func add(name: String, accountLabel: String) {
        let profile = ClaudeProfile(name: name.trimmed, accountLabel: accountLabel.trimmed)
        profiles.append(profile)
        selectedProfileID = profile.id
        save()
    }

    func update(_ profile: ClaudeProfile, name: String, accountLabel: String) {
        guard let index = profiles.firstIndex(of: profile) else { return }
        profiles[index].name = name.trimmed
        profiles[index].accountLabel = accountLabel.trimmed
        save()
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

    func launch(_ profile: ClaudeProfile) {
        if let runningApp = runningApps[profile.id], !runningApp.isTerminated {
            runningApp.activate(options: [.activateAllWindows])
            return
        }
        guard fileManager.fileExists(atPath: claudeURL.path) else {
            showError("Claude Desktop wasn’t found in /Applications/Claude.app.")
            return
        }

        do {
            try fileManager.createDirectory(at: dataDirectory(for: profile), withIntermediateDirectories: true)
            let existingPIDs = Set(
                NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleIdentifier)
                    .map(\.processIdentifier)
            )
            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            launcher.arguments = [
                "-na", claudeURL.path,
                "--args", "--user-data-dir=\(dataDirectory(for: profile).path)"
            ]
            launchProcesses[profile.id] = launcher
            launcher.terminationHandler = { [weak self] completedLauncher in
                let status = completedLauncher.terminationStatus
                DispatchQueue.main.async {
                    self?.launchProcesses.removeValue(forKey: profile.id)
                    guard status == 0 else {
                        self?.showError("Couldn’t launch Claude (open exited with status \(status)).")
                        return
                    }
                    self?.trackNewClaudeInstance(for: profile, excluding: existingPIDs, attemptsRemaining: 10)
                }
            }
            try launcher.run()
        } catch {
            showError("Couldn’t prepare the profile folder: \(error.localizedDescription)")
        }
    }

    func stop(_ profile: ClaudeProfile) {
        guard let app = runningApps[profile.id], !app.isTerminated else { return }
        if !app.terminate() {
            _ = app.forceTerminate()
        }
        runningApps.removeValue(forKey: profile.id)
        objectWillChange.send()
    }

    func moveToTrash(_ profile: ClaudeProfile) {
        guard !isRunning(profile) else {
            showError("Stop the profile before moving it to Trash.")
            return
        }
        do {
            let directory = dataDirectory(for: profile)
            if fileManager.fileExists(atPath: directory.path) {
                _ = try fileManager.trashItem(at: directory, resultingItemURL: nil)
            }
            profiles.removeAll { $0.id == profile.id }
            if selectedProfileID == profile.id { selectedProfileID = profiles.first?.id }
            save()
        } catch {
            showError("Couldn’t move \"\(profile.name)\" to Trash: \(error.localizedDescription)")
        }
    }

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

    private func trackNewClaudeInstance(
        for profile: ClaudeProfile,
        excluding existingPIDs: Set<pid_t>,
        attemptsRemaining: Int
    ) {
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: claudeBundleIdentifier)
        if let newApp = apps.first(where: { !existingPIDs.contains($0.processIdentifier) }) {
            runningApps[profile.id] = newApp
            objectWillChange.send()
            return
        }
        guard attemptsRemaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.trackNewClaudeInstance(
                for: profile,
                excluding: existingPIDs,
                attemptsRemaining: attemptsRemaining - 1
            )
        }
    }

    private func showError(_ message: String) {
        errorMessage = message
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
