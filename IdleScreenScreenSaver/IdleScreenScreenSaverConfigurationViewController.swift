import AppKit
import OSLog

private let configurationLogger = Logger(
    subsystem: "com.idlescreen.screensaver",
    category: "Configuration"
)

@objc(IdleScreenScreenSaverConfigurationViewController)
class IdleScreenScreenSaverConfigurationViewController: ScreenSaverConfigurationViewController {
    private let sheetSize = NSSize(width: 360, height: 150)

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func loadView() {
        let contentView = NSView(frame: NSRect(origin: .zero, size: sheetSize))

        let titleLabel = NSTextField(labelWithString: "idlescreen options")
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        titleLabel.alignment = .center

        let detailLabel = NSTextField(
            wrappingLabelWithString: "Open the idlescreen app to change visuals, camera, and saver settings."
        )
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 2

        let openButton = NSButton(
            title: "Open idlescreen",
            target: self,
            action: #selector(openCompanionApp(_:))
        )
        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"

        let doneButton = NSButton(
            title: "Done",
            target: self,
            action: #selector(dismissSheet(_:))
        )
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\u{1b}"

        let buttonRow = NSStackView(views: [openButton, doneButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        buttonRow.alignment = .centerY

        let stack = NSStackView(views: [titleLabel, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            contentView.widthAnchor.constraint(equalToConstant: sheetSize.width),
            contentView.heightAnchor.constraint(equalToConstant: sheetSize.height),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 310),
        ])

        view = contentView
        preferredContentSize = sheetSize
    }

    @objc private func openCompanionApp(_ sender: Any?) {
        let extensionURL = Bundle(for: Self.self).bundleURL
        let appURL = extensionURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        guard appURL.pathExtension == "app" else {
            configurationLogger.error(
                "Could not resolve containing app from extension at \(extensionURL.path, privacy: .public)"
            )
            NSSound.beep()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: appURL,
            configuration: configuration,
            completionHandler: { _, error in
                if let error {
                    configurationLogger.error(
                        "Could not open containing app: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        )
        dismissSheet(sender)
    }

    @objc private func dismissSheet(_ sender: Any?) {
        configureSheetDidEnd()
    }
}
