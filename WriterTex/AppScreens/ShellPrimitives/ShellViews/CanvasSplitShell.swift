import SwiftUI

/// AppKit owns divider geometry; SwiftUI only supplies each pane's content.
/// Column floors, shared by the split items and the window's minimum size.
private enum CanvasColumns {
    static let sidebarMinimum: CGFloat = 250
    static let contentMinimum: CGFloat = 400
    static let inspectorMinimum: CGFloat = 260
    static let minimumHeight: CGFloat = 560
}

/// Sidebar · content · inspector columns, or sidebar · content when
/// `showsInspector` is nil. AppKit owns the column widths.
///
/// `HSplitView` re-applied each pane's ideal width whenever its content
/// changed, so opening a file in the editor snapped a dragged sidebar back to
/// its default. Panes never propose a size.
struct CanvasSplitView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var showsSidebar: Bool
    /// Nil for a window with no inspector column.
    var showsInspector: Binding<Bool>?
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let content: Content
    @ViewBuilder let inspector: Inspector


    func makeNSViewController(context: Context) -> Controller {
        Controller(sidebar: sidebar, content: content, inspector: showsInspector == nil ? nil : inspector)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.sidebar.rootView = sidebar
        controller.content.rootView = content
        controller.inspector?.rootView = inspector
        controller.onCollapseChange = { index, collapsed in
            if index == 0 { showsSidebar = !collapsed } else if let showsInspector { showsInspector.wrappedValue = !collapsed }
        }
        controller.setCollapsed(!showsSidebar, at: 0)
        if let showsInspector { controller.setCollapsed(!showsInspector.wrappedValue, at: 2) }
    }

    /// Same reason as `ProjectSplitView`: a column drag must never feed the
    /// split's fitting size back into SwiftUI's layout of the window. The one
    /// exception is the floor: the open columns' minimums, which the window
    /// (`.windowResizability(.contentSize)`) takes as its minimum size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions()
        var minimumWidth = CanvasColumns.contentMinimum
        if showsSidebar { minimumWidth += CanvasColumns.sidebarMinimum + 1 }
        if showsInspector?.wrappedValue == true { minimumWidth += CanvasColumns.inspectorMinimum + 1 }
        return CGSize(width: max(size.width, minimumWidth), height: max(size.height, CanvasColumns.minimumHeight))
    }

    final class Controller: NSSplitViewController {
        let sidebar: NSHostingController<Sidebar>
        let content: NSHostingController<Content>
        let inspector: NSHostingController<Inspector>?
        /// Collapse state per column as SwiftUI last set or was last told it.
        private var collapsed: [Int: Bool] = [:]
        private var collapseObservations: [NSKeyValueObservation] = []
        var onCollapseChange: ((Int, Bool) -> Void)?

        init(sidebar: Sidebar, content: Content, inspector: Inspector?) {
            self.sidebar = NSHostingController(rootView: sidebar)
            self.content = NSHostingController(rootView: content)
            self.inspector = inspector.map { NSHostingController(rootView: $0) }
            super.init(nibName: nil, bundle: nil)
            self.sidebar.sizingOptions = []
            self.content.sizingOptions = []
            self.inspector?.sizingOptions = []

            let sidebarItem = NSSplitViewItem(viewController: self.sidebar)
            sidebarItem.minimumThickness = CanvasColumns.sidebarMinimum
            sidebarItem.canCollapse = true
            // Window resizes go to the content column, not the side columns.
            sidebarItem.holdingPriority = .init(rawValue: 260)
            let contentItem = NSSplitViewItem(viewController: self.content)
            contentItem.minimumThickness = CanvasColumns.contentMinimum
            addSplitViewItem(sidebarItem)
            addSplitViewItem(contentItem)
            var collapsible = [(0, sidebarItem)]
            if let inspector = self.inspector {
                let inspectorItem = NSSplitViewItem(viewController: inspector)
                inspectorItem.minimumThickness = CanvasColumns.inspectorMinimum
                inspectorItem.canCollapse = true
                inspectorItem.holdingPriority = .init(rawValue: 260)
                addSplitViewItem(inspectorItem)
                collapsible.append((2, inspectorItem))
            }
            // A divider drag or window resize collapses a column inside AppKit.
            // Report it, or the next SwiftUI update re-opens the column and the
            // toolbar button's first click only catches its state back up.
            for (index, item) in collapsible {
                collapseObservations.append(item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.collapsed[index] != item.isCollapsed else { return }
                        self.collapsed[index] = item.isCollapsed
                        self.onCollapseChange?(index, item.isCollapsed)
                    }
                })
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setCollapsed(_ collapsed: Bool, at index: Int) {
            // Recorded first so the collapse observer sees no change to report.
            self.collapsed[index] = collapsed
            let item = splitViewItems[index]
            if item.isCollapsed != collapsed {
                item.isCollapsed = collapsed
                splitView.layoutSubtreeIfNeeded()
            }
        }
    }
}

extension CanvasSplitView where Inspector == EmptyView {
    /// Sidebar · content, with no inspector column.
    init(showsSidebar: Binding<Bool>, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content) {
        self.init(showsSidebar: showsSidebar, showsInspector: nil, sidebar: sidebar, content: content, inspector: { EmptyView() })
    }
}
