import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case niri
    case dwindle
    case workspaces
    case borders
    case bar

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .general: "General"
        case .niri: "Niri Layout"
        case .dwindle: "Dwindle Layout"
        case .workspaces: "Workspaces"
        case .borders: "Borders"
        case .bar: "Workspace Bar"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape"
        case .niri: "scroll"
        case .dwindle: "square.split.2x2"
        case .workspaces: "rectangle.3.group"
        case .borders: "square.dashed"
        case .bar: "menubar.rectangle"
        }
    }
}

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case basics = "Basics"
    case layouts = "Layouts"
    case workspace = "Workspace"

    var id: String {
        rawValue
    }

    var sections: [SettingsSection] {
        switch self {
        case .basics:
            [.general]
        case .layouts:
            [.niri, .dwindle]
        case .workspace:
            [.workspaces, .borders, .bar]
        }
    }
}
