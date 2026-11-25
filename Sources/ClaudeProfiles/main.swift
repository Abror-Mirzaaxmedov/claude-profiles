import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ProfileStore()
    private var windowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }

        let contentController = ProfilesViewController(store: store)
        let window = NSWindow(contentViewController: contentController)
        window.title = "Claude Profiles"
        window.setContentSize(NSSize(width: 760, height: 500))
        window.minSize = NSSize(width: 680, height: 440)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.titlebarAppearsTransparent = true
        window.center()
        let controller = NSWindowController(window: window)
        windowController = controller
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
private final class ProfilesViewController: NSViewController {
    private let store: ProfileStore
    private let cardsStack = NSStackView()
    private let addButton = NSButton(title: "Add profile", target: nil, action: nil)
    private let footer = NSTextField(wrappingLabelWithString: "")
    private var cancellable: AnyCancellable?

    init(store: ProfileStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        cancellable = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.reload() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "Claude Profiles")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        let subtitle = NSTextField(labelWithString: "Two isolated Claude spaces. One simple launcher.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [title, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 4

        addButton.target = self
        addButton.action = #selector(addProfile)
        addButton.bezelStyle = .rounded
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.contentTintColor = .controlAccentColor

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        addButton.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleStack)
        header.addSubview(addButton)
        NSLayoutConstraint.activate([
            titleStack.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            addButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            header.heightAnchor.constraint(greaterThanOrEqualToConstant: 54)
        ])

        cardsStack.orientation = .vertical
        cardsStack.alignment = .leading
        cardsStack.spacing = 12
        cardsStack.translatesAutoresizingMaskIntoConstraints = false

        footer.font = .systemFont(ofSize: 12)
        footer.textColor = .tertiaryLabelColor
        footer.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(header)
        view.addSubview(cardsStack)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            cardsStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            cardsStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            cardsStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 26),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -24)
        ])
        reload()
    }

    private func reload() {
        cardsStack.arrangedSubviews.forEach {
            cardsStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        if store.profiles.isEmpty {
            cardsStack.addArrangedSubview(makeEmptyState())
        } else {
            for (index, profile) in store.profiles.prefix(2).enumerated() {
                cardsStack.addArrangedSubview(makeProfileCard(profile, index: index))
            }
        }
        addButton.isHidden = store.profiles.count >= 2
        addButton.toolTip = "Add a second isolated Claude profile"
        updateFooter()
    }

    private func updateFooter() {
        var parts = ["Local only  •  Separate sessions  •  No cloud sync"]
        footer.textColor = .tertiaryLabelColor
        switch store.defaultFolderStatus {
        case .linked:
            if let profile = store.defaultProfile {
                parts.append("Dock, Spotlight and Claude updates open \"\(profile.name)\".")
            }
        case .blockedByRealFolder:
            footer.textColor = .systemOrange
            parts.append("~/Library/Application Support/Claude is a separate, unmanaged Claude folder: opening Claude from the Dock or after an update signs into that one, not your profiles. Quit Claude and move that folder away to fix it.")
        case .failed(let reason):
            footer.textColor = .systemOrange
            parts.append("Couldn’t link the default Claude folder: \(reason)")
        case .none:
            break
        }
        if store.unmanagedInstanceCount > 0 {
            footer.textColor = .systemOrange
            parts.append("\(store.unmanagedInstanceCount) Claude window(s) are running outside your profiles.")
        }
        footer.stringValue = parts.joined(separator: "\n")
    }

    private func makeEmptyState() -> NSView {
        let card = cardBackground()
        let icon = NSImageView(image: NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        let headline = NSTextField(labelWithString: "Create your first space")
        headline.font = .systemFont(ofSize: 17, weight: .semibold)
        let detail = NSTextField(labelWithString: "Add Personal or Work, then sign in when you launch it.")
        detail.textColor = .secondaryLabelColor
        let create = NSButton(title: "Create profile", target: self, action: #selector(addProfile))
        create.bezelStyle = .rounded
        create.contentTintColor = .controlAccentColor
        [icon, headline, detail, create].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 132),
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            icon.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            headline.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 18),
            headline.topAnchor.constraint(equalTo: card.topAnchor, constant: 35),
            detail.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            detail.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
            create.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            create.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        return card
    }

    private func makeProfileCard(_ profile: ClaudeProfile, index: Int) -> NSView {
        let card = cardBackground()
        let isRunning = store.isRunning(profile)
        let avatar = makeAvatar(letter: profile.name.prefix(1).uppercased(), color: index == 0 ? .systemIndigo : .systemOrange)
        let name = NSTextField(labelWithString: profile.name)
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        var accountParts = [profile.accountLabel.isEmpty ? "No account label" : profile.accountLabel]
        if !store.isSignedIn(profile) { accountParts.append("not signed in yet") }
        if store.isDefault(profile) { accountParts.append("default — opens from Dock") }
        let account = NSTextField(labelWithString: accountParts.joined(separator: "  •  "))
        account.lineBreakMode = .byTruncatingTail
        account.font = .systemFont(ofSize: 13)
        account.textColor = .secondaryLabelColor
        let status = makeStatusBadge(isRunning ? "RUNNING" : "READY", active: isRunning)

        let launch = ProfileButton(title: isRunning ? "Show Claude" : "Launch", target: self, action: #selector(launchProfile(_:)))
        launch.profileID = profile.id
        launch.image = NSImage(systemSymbolName: isRunning ? "arrow.up.forward.app.fill" : "play.fill", accessibilityDescription: nil)
        launch.imagePosition = .imageLeading
        launch.bezelStyle = .rounded
        launch.controlSize = .large
        launch.bezelColor = .controlAccentColor
        launch.contentTintColor = .white

        let actions = ProfileSegmentedControl(labels: [], trackingMode: .momentary, target: self, action: #selector(profileAction(_:)))
        actions.profileID = profile.id
        let isDefault = store.isDefault(profile)
        actions.segmentCount = 4
        actions.setImage(NSImage(systemSymbolName: isDefault ? "star.fill" : "star", accessibilityDescription: "Make default"), forSegment: 0)
        actions.setImage(NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Claude"), forSegment: 1)
        actions.setImage(NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit profile"), forSegment: 2)
        actions.setImage(NSImage(systemSymbolName: "trash", accessibilityDescription: "Move profile to Trash"), forSegment: 3)
        (0..<4).forEach { actions.setWidth(36, forSegment: $0) }
        actions.setEnabled(!isDefault, forSegment: 0)
        actions.setEnabled(isRunning, forSegment: 1)
        actions.setToolTip(isDefault ? "Default profile: Dock, Spotlight and updates open it" : "Make default (opens from Dock, Spotlight and after updates)", forSegment: 0)
        actions.setToolTip("Stop Claude", forSegment: 1)
        actions.setToolTip("Edit profile", forSegment: 2)
        actions.setToolTip("Move profile to Trash", forSegment: 3)

        [avatar, name, account, status, launch, actions].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; card.addSubview($0) }
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 124),
            avatar.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            avatar.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 58),
            avatar.heightAnchor.constraint(equalToConstant: 58),
            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 16),
            name.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            status.leadingAnchor.constraint(equalTo: name.trailingAnchor, constant: 10),
            status.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            status.widthAnchor.constraint(equalToConstant: 82),
            status.heightAnchor.constraint(equalToConstant: 24),
            account.leadingAnchor.constraint(equalTo: name.leadingAnchor),
            account.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 6),
            actions.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            actions.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            actions.heightAnchor.constraint(equalToConstant: 34),
            actions.widthAnchor.constraint(equalToConstant: 148),
            account.trailingAnchor.constraint(lessThanOrEqualTo: launch.leadingAnchor, constant: -12),
            launch.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -10),
            launch.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            launch.heightAnchor.constraint(equalToConstant: 38),
            launch.widthAnchor.constraint(greaterThanOrEqualToConstant: 134)
        ])
        return card
    }

    private func cardBackground() -> NSVisualEffectView {
        let card = NSVisualEffectView()
        card.material = .sidebar
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        card.layer?.borderWidth = 0.5
        return card
    }

    private func makeAvatar(letter: String, color: NSColor) -> NSView {
        let avatar = NSView()
        avatar.wantsLayer = true
        avatar.layer?.backgroundColor = color.withAlphaComponent(0.2).cgColor
        avatar.layer?.cornerRadius = 16
        let label = NSTextField(labelWithString: letter)
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = color
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: avatar.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: avatar.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)
        ])
        return avatar
    }

    private func makeStatusBadge(_ value: String, active: Bool) -> NSTextField {
        let badge = CenteredBadgeLabel()
        badge.stringValue = value
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = active ? .systemGreen : .secondaryLabelColor
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 12
        badge.layer?.backgroundColor = (active ? NSColor.systemGreen : NSColor.secondaryLabelColor).withAlphaComponent(0.12).cgColor
        return badge
    }

    @objc private func addProfile() {
        guard store.profiles.count < 2 else { return }
        let suggestion = store.profiles.isEmpty ? "Personal" : "Work"
        guard let values = profileDialog(title: "New Claude Profile", name: suggestion, accountLabel: "") else { return }
        store.add(name: values.name, accountLabel: values.accountLabel)
        reload()
        showErrorIfNeeded()
    }

    @objc private func launchProfile(_ sender: NSButton) {
        guard let profile = profile(for: sender) else { return }
        let others = store.otherRunningProfiles(than: profile)
        if !store.isRunning(profile), !store.isSignedIn(profile), !others.isEmpty {
            // Claude finishes browser sign-in through a claude:// link, and macOS hands that link
            // to whichever Claude instance it likes — often the other profile, which then gets
            // the wrong account (or this one never gets signed in).
            let names = others.map(\.name).joined(separator: ", ")
            let alert = NSAlert()
            alert.messageText = "Close \(names) while you sign in?"
            alert.informativeText = "Claude finishes sign-in through a link from the browser. With two Claude windows open, macOS may deliver it to \(names) instead of \(profile.name), mixing up the accounts. Reopen \(names) after you have signed in."
            alert.addButton(withTitle: "Close and Launch")
            alert.addButton(withTitle: "Launch Anyway")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                store.stop(others) { [weak self] in
                    self?.store.launch(profile)
                    self?.reload()
                    self?.showErrorIfNeeded()
                }
                return
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        store.launch(profile)
        reload()
        showErrorIfNeeded()
    }

    @objc private func profileAction(_ sender: ProfileSegmentedControl) {
        guard let profile = profile(for: sender) else { return }
        switch sender.selectedSegment {
        case 0:
            store.makeDefault(profile)
            reload()
            showErrorIfNeeded()
        case 1:
            store.stop(profile)
            reload()
        case 2:
            guard let values = profileDialog(title: "Edit \(profile.name)", name: profile.name, accountLabel: profile.accountLabel) else { return }
            store.update(profile, name: values.name, accountLabel: values.accountLabel)
            reload()
            showErrorIfNeeded()
        case 3:
            confirmDelete(profile)
        default:
            break
        }
    }

    private func confirmDelete(_ profile: ClaudeProfile) {
        let alert = NSAlert()
        alert.messageText = "Move \(profile.name) to Trash?"
        alert.informativeText = "Its local Claude session and history will be moved to the macOS Trash."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.moveToTrash(profile)
        reload()
        showErrorIfNeeded()
    }

    private func profile(for sender: NSControl) -> ClaudeProfile? {
        let id = (sender as? ProfileButton)?.profileID ?? (sender as? ProfileSegmentedControl)?.profileID
        guard let id else { return nil }
        return store.profiles.first { $0.id == id }
    }

    private func profileDialog(title: String, name initialName: String, accountLabel initialAccountLabel: String) -> (name: String, accountLabel: String)? {
        let name = NSTextField(string: initialName)
        let account = NSTextField(string: initialAccountLabel)
        name.placeholderString = "Personal"
        account.placeholderString = "name@example.com or Work account"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 94))
        let nameTitle = NSTextField(labelWithString: "Profile name")
        let accountTitle = NSTextField(labelWithString: "Account label")
        [nameTitle, accountTitle].forEach { $0.font = .systemFont(ofSize: 12, weight: .medium) }
        nameTitle.frame = NSRect(x: 0, y: 76, width: 340, height: 17)
        name.frame = NSRect(x: 0, y: 49, width: 340, height: 24)
        accountTitle.frame = NSRect(x: 0, y: 28, width: 340, height: 17)
        account.frame = NSRect(x: 0, y: 1, width: 340, height: 24)
        [nameTitle, name, accountTitle, account].forEach(form.addSubview)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "This label stays on your Mac. It does not sign in to Claude."
        alert.accessoryView = form
        alert.addButton(withTitle: title.hasPrefix("New") ? "Create" : "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              !name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (name.stringValue, account.stringValue)
    }

    private func showErrorIfNeeded() {
        guard let message = store.errorMessage else { return }
        store.errorMessage = nil
        NSAlert(error: NSError(domain: "ClaudeProfiles", code: 1, userInfo: [NSLocalizedDescriptionKey: message])).runModal()
    }
}

private final class ProfileButton: NSButton {
    var profileID: UUID?
}

private final class ProfileSegmentedControl: NSSegmentedControl {
    var profileID: UUID?
}

private final class CenteredBadgeLabel: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byClipping
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(
            string: stringValue,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: textColor ?? NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
        let textHeight = text.boundingRect(
            with: NSSize(width: bounds.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]
        ).height
        let rect = NSRect(x: 0, y: (bounds.height - textHeight) / 2, width: bounds.width, height: textHeight)
        text.draw(in: rect)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
