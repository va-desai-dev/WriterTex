//
//  CanvasView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI

/// Shared window chrome. Feature state belongs to the selected workspace view.
struct CanvasView<Content: View, Sidebar: View, Inspector: View>: View {

    @Binding var showsInspector: Bool
    @ViewBuilder let content: Content
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let inspector: Inspector
    @State private var showsSidebar = true
    @State private var theme = AppTheme.shared


    var body: some View {
        CanvasSplitView(showsSidebar: $showsSidebar, showsInspector: $showsInspector) {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } content: {
            content
        } inspector: {
            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(showsSidebar ? "Hide sidebar" : "Show sidebar")
            }
            if #available(macOS 26.0, *) {
                ToolbarSpacer()
                    .sharedBackgroundVisibility(.hidden)
            }
            ToolbarItem {
                Button {
                    showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showsInspector ? "Hide inspector" : "Show inspector")
            }
        }
        .toolbar(removing: .title)
        .containerBackground(theme.windowBackground,
                             for: .window
        )
        .toolbarBackground(theme.paneBackground, for: .windowToolbar)
    }
}

