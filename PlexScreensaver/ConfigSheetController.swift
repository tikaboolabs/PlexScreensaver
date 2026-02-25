import AppKit
import ScreenSaver

final class ConfigSheetController: NSObject {
    let window: NSWindow
    private let serverField = NSTextField()
    private let tokenField = NSSecureTextField()

    override init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
                         styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "Plex Screensaver Settings"
        self.window = w
        super.init()
        buildUI()
    }

    /// Reload current values into the fields (call before presenting)
    func reloadFields() {
        serverField.stringValue = PlexScreensaverView.serverUrl
        tokenField.stringValue = PlexScreensaverView.token
    }

    private func buildUI() {
        guard let content = window.contentView else { return }

        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Plex Screensaver Configuration")
        titleLabel.font = .boldSystemFont(ofSize: 16)
        titleLabel.frame = NSRect(x: 20, y: 190, width: 380, height: 24)
        content.addSubview(titleLabel)

        let serverLabel = NSTextField(labelWithString: "Server URL:")
        serverLabel.frame = NSRect(x: 20, y: 150, width: 100, height: 22)
        content.addSubview(serverLabel)

        serverField.frame = NSRect(x: 130, y: 150, width: 270, height: 22)
        serverField.placeholderString = "http://192.168.1.100:32400"
        serverField.stringValue = PlexScreensaverView.serverUrl
        content.addSubview(serverField)

        let tokenLabel = NSTextField(labelWithString: "Plex Token:")
        tokenLabel.frame = NSRect(x: 20, y: 115, width: 100, height: 22)
        content.addSubview(tokenLabel)

        tokenField.frame = NSRect(x: 130, y: 115, width: 270, height: 22)
        tokenField.placeholderString = "Your Plex authentication token"
        tokenField.stringValue = PlexScreensaverView.token
        content.addSubview(tokenField)

        let helpLabel = NSTextField(wrappingLabelWithString: "Find your token at app.plex.tv > Settings > Account > XML")
        helpLabel.font = .systemFont(ofSize: 11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.frame = NSRect(x: 130, y: 80, width: 270, height: 30)
        content.addSubview(helpLabel)

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.frame = NSRect(x: 220, y: 20, width: 80, height: 32)
        cancelBtn.bezelStyle = .rounded
        content.addSubview(cancelBtn)

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.frame = NSRect(x: 310, y: 20, width: 80, height: 32)
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        content.addSubview(saveBtn)
    }

    private func dismissSheet(returnCode: NSApplication.ModalResponse) {
        if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: returnCode)
        } else {
            // Fallback for macOS versions where sheetParent is nil
            NSApp.endSheet(window, returnCode: returnCode.rawValue)
            window.orderOut(nil)
        }
    }

    @objc private func save() {
        PlexScreensaverView.serverUrl = serverField.stringValue
        PlexScreensaverView.token = tokenField.stringValue
        dismissSheet(returnCode: .OK)
    }

    @objc private func cancel() {
        dismissSheet(returnCode: .cancel)
    }
}
