# Archived web browser

The embedded web browser was removed from WriterTex's compiling sources on
2026-11-04. The model, pane, header controls, and integration check are retained
here for possible reuse in a future statistics feature.

Original locations:

- `AppClasses/BrowserModel.swift`: `WriterTex/AppClasses/WebKitControl/BrowserModel.swift`
- `AppScreens/BrowserView.swift`: `WriterTex/AppScreens/CanvasViews/WorkspacePanelViews/BrowserView.swift`
- `AppScreens/BrowserPane.swift`: `WriterTex/AppScreens/CanvasViews/Headers+Footers/BrowserPane.swift`
- `Tests/BrowserIntegrationChecks.swift`: `Tests/BrowserIntegrationChecks.swift`

The writing pane no longer mounts WebKit or exposes a browser toggle. The
bibliography browser and CiteTex Safari extension remain active; they are
separate features. This archive is outside Xcode's synchronized app source root.
