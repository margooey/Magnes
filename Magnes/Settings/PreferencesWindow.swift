import Cocoa

final class PreferencesWindowController: NSWindowController {
    init() {
        let contentViewController = PreferencesViewController()
        let window = NSWindow(contentViewController: contentViewController)
        window.title = "Magnes Preferences"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class PreferencesViewController: NSViewController {
    private let settings = SettingsManager.shared
    private lazy var magneticToggle: NSButton = {
        let button = NSButton(checkboxWithTitle: "Enable Magnetic Snapping", target: self, action: #selector(toggleMagneticSnapping(_:)))
        return button
    }()

    private lazy var hoverToggle: NSButton = {
        let button = NSButton(checkboxWithTitle: "Enable Hover Effects", target: self, action: #selector(toggleHoverEffects(_:)))
        return button
    }()

    private lazy var frictionSlider: NSSlider = {
        let slider = NSSlider(value: 0.92, minValue: 0.80, maxValue: 0.99, target: self, action: #selector(frictionChanged(_:)))
        slider.numberOfTickMarks = 4
        slider.allowsTickMarkValuesOnly = false
        return slider
    }()

    private let frictionLabel = NSTextField(labelWithString: "Momentum Friction")
    private lazy var sensitivitySlider: NSSlider = {
        let slider = NSSlider(value: 0.34, minValue: 0.18, maxValue: 0.70, target: self, action: #selector(sensitivityChanged(_:)))
        slider.numberOfTickMarks = 6
        slider.allowsTickMarkValuesOnly = false
        return slider
    }()
    private let sensitivityLabel = NSTextField(labelWithString: "Cursor Sensitivity")

    override func loadView() {
        view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        layoutPreferences()
        syncSettings()
    }

    private func layoutPreferences() {
        let stackView = NSStackView(views: [
            labeledRow(label: sensitivityLabel, control: sensitivitySlider),
            labeledRow(label: frictionLabel, control: frictionSlider),
            magneticToggle,
            hoverToggle
        ])
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
            view.widthAnchor.constraint(equalToConstant: 360),
            view.heightAnchor.constraint(equalToConstant: 220)
        ])
    }

    private func labeledRow(label: NSTextField, control: NSControl) -> NSView {
        let container = NSStackView(views: [label, control])
        container.orientation = .horizontal
        container.alignment = .firstBaseline
        container.spacing = 12
        return container
    }

    private func syncSettings() {
        magneticToggle.state = settings.magneticSnappingEnabled ? .on : .off
        hoverToggle.state = settings.hoverEffectsEnabled ? .on : .off
        frictionSlider.doubleValue = settings.momentumFriction
        sensitivitySlider.doubleValue = settings.pointerSensitivity
    }

    @objc private func toggleMagneticSnapping(_ sender: NSButton) {
        settings.magneticSnappingEnabled = sender.state == .on
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func toggleHoverEffects(_ sender: NSButton) {
        settings.hoverEffectsEnabled = sender.state == .on
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func frictionChanged(_ sender: NSSlider) {
        settings.momentumFriction = sender.doubleValue
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }

    @objc private func sensitivityChanged(_ sender: NSSlider) {
        settings.pointerSensitivity = sender.doubleValue
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let settingsDidChange = Notification.Name("com.example.iPadCursor.settingsDidChange")
    static let cursorEngineStateDidChange = Notification.Name("com.example.iPadCursor.cursorEngineStateDidChange")
}

