//
//  EntryView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/19/26.
//

import SwiftUI

/// The welcome window: start a manuscript or a notebook, or reopen one.
struct EntryView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("WriterTex.welcomeMode") private var mode = AppModes.files
    @State private var recents: [URL] = []
    @State private var selection: URL?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image("WriterTexLogo")
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.original)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                Text("WriterTex")
                    .font(.title)
                    .fontWeight(.bold)
                Text("Version \(AppVersion.current)")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Copyright © 2026 Vedant A. Desai")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            if #available(macOS 27.0, *) {
                modePicker.pickerStyle(.tabs)
            } else {
                modePicker.pickerStyle(.segmented)
            }
            List(recents, id: \.self) { url in
                Button { open(url) } label: {
                    RecentItemRow(
                        title: url.deletingPathExtension().lastPathComponent,
                        path: url.deletingLastPathComponent().path,
                        isSelected: selection == url,
                        icon: mode.fileIcon, icontint: mode.fileIconColor
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open \(url.lastPathComponent)")
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if recents.isEmpty {
                    ContentUnavailableView(
                        mode == .files ? "No Recent Manuscripts" : "No Recent Notebooks",
                        systemImage: mode.symbol,
                        description: Text(mode == .files
                            ? "A manuscript is one .wrtx file that cites one .bib bibliography."
                            : "A notebook is one .wrstatx file that carries its own CSV datasets.")
                    )
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button {
                    mode.makeNew(with: newDocument)
                    dismissWindow()
                } label: {
                    HStack {
                        Text(mode.newLabel)
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.glassTitleButton)
                .keyboardShortcut(.defaultAction)
                Spacer()
                Button(action: showOpenPanel) {
                    HStack{
                        Text("Open Existing")
                    }
                    .padding(.horizontal)
                }
                .buttonStyle(.glassTitleButton)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 420, height: 780)
        .background(AppTheme.shared.windowBackground)
        .onChange(of: mode, initial: true) { refreshRecents() }
        // Documents opened or saved elsewhere since the window last showed.
        .onAppear(perform: refreshRecents)
    }

    private var modePicker: some View {
        Picker("Document Type", selection: $mode) {
            ForEach(AppModes.allCases) { mode in
                Label { Text(mode.rawValue) } icon: { mode.icon }
                    .tag(mode)
            }
        }
        .labelsHidden()
        .controlSize(.extraLarge)
    }

    private func refreshRecents() {
        recents = NSDocumentController.shared.recentDocumentURLs.filter(mode.opens)
        error = nil
    }

    private func showOpenPanel() {
        NSDocumentController.shared.beginOpenPanel { urls in
            guard let url = urls?.first else { return }
            open(url)
        }
    }

    private func open(_ url: URL) {
        selection = url
        Task {
            do {
                try await openDocument(at: url)
                dismissWindow()
            } catch {
                self.error = error.localizedDescription
                selection = nil
                refreshRecents()
            }
        }
    }
}

struct RecentItemRow: View {
    let title: String
    let path: String
    let isSelected: Bool
    var icon = Image(systemName: "doc.text.fill")
    var icontint: Color

    var body: some View {
        HStack {
            icon
                .foregroundStyle(icontint)
                .font(.system(size: 26))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? .white : .primary)
    }
}
