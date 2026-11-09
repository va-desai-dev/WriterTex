//
//  SettingsView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/25/26.
//

import SwiftUI

enum IDESettingsTab: String, CaseIterable, Identifiable {
    case themes = "Theme"

    var id: String { self.rawValue }

    var iconName: String {
        switch self {
        case .themes: return "paintpalette.fill"
        }
    }
}


/// The master settings window. Every pane works on the same user defaults and
/// stores the in-window menus and welcome window already use, so the two stay
/// in step.
struct IDESettingsView: View {
    @State private var selectedTab: IDESettingsTab = .themes

    var body: some View {
        HStack {
            List(IDESettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.iconName)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 180)
            Group {
                switch selectedTab {
                    case .themes:
                        EditorThemeControls()
                            .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.foreground)
        .tint(Color.accentColor)
        .frame(width: 720, height: 520)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
