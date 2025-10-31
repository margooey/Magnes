import CoreFoundation

/// Convenience wrappers around Accessibility constant strings so we avoid relying
/// on availability of the legacy kAX* symbols in Swift.
enum AXRole {
    static let button = "AXButton"
    static let link = "AXLink"
    static let radioButton = "AXRadioButton"
    static let checkBox = "AXCheckBox"
    static let textField = "AXTextField"
    static let popUpButton = "AXPopUpButton"

    // Web content often maps to these role names.
    static let webArea = "AXWebArea"
    static let group = "AXGroup"
    static let list = "AXList"
    static let listItem = "AXListItem"
    static let row = "AXRow"
    static let cell = "AXCell"
    static let table = "AXTable"
    static let outline = "AXOutline"
    static let collection = "AXCollection"
    static let staticText = "AXStaticText"

    // Menu structures.
    static let menu = "AXMenu"
    static let menuItem = "AXMenuItem"
    static let menuBar = "AXMenuBar"
}

enum AXSubrole {
    static let closeButton = "AXCloseButton"
}

enum AXTrustedCheckOption {
    static let prompt = "AXTrustedCheckOptionPrompt" as CFString
}

enum AXActionName {
    static let press = "AXPress" as CFString
}