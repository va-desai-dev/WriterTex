# Running the checks

Build the app once, then compile and run any check against that build:

```sh
xcodebuild -project WriterTex.xcodeproj -scheme WriterTex -configuration Debug \
  -derivedDataPath <DerivedData> CODE_SIGNING_ALLOWED=NO build
python3 Tests/run-checks.py <DerivedData>
```

With no check names the runner runs every `*Checks.swift` and prints a summary;
name one or more files to run just those. Each check is compiled with
`Tests/Support/*.swift` and runs with its own temporary home folder, so the
preferences and recent documents never touch your account. Checks that
open windows need a logged-in macOS GUI session.

# Find-bar keyboard focus checks

```sh
python3 Tests/run-checks.py <DerivedData> FindFocusIntegrationChecks.swift
```

Types `Bar`, waits for incremental matching, then finishes `Barrett` in the real
inline find field against a long document. Verifies the document is unchanged,
Next/Previous preserve field focus, Replace-and-Find preserves an independently
focused native replacement field, and dismissing Find returns focus to the editor.
Restores the shared Find pasteboard after the check.

# Formatted editor checks

```sh
python3 Tests/run-checks.py <DerivedData> MarkdownFindIntegrationChecks.swift
```

Mounts two Formatted (rich-text) editors with the production find bar,
driven by the code editor's TextFinder. Fixtures are written in Markdown shorthand
and imported, and results are compared as document outlines
(`Tests/Support/ManuscriptFixture.swift`), never as Markdown. Checks that no syntax
is on screen, that typed delimiters apply inline formatting and survive reopening,
while pasted plain text stays literal, that loading leaves the document unchanged,
that editing a table cell changes only that cell and undo restores the document
exactly, Tab between cells, quotes laid out
at full width, editing a paragraph that ends in an emoji, Command-F,
query-field focus while typing and navigating, match counts and selected ranges,
replacement binding updates and undo/redo, pane isolation, and switching
modes/files while Find is open. Restores the shared Find pasteboard and find
options afterward.

# Bibliography inspector checks

```sh
python3 Tests/run-checks.py <DerivedData> BibliographyInspectorChecks.swift
```

Checks Markdown-only eligibility, author/title/journal search, ordered Pandoc
citations with duplicate keys, and selection reset. Renders long filenames,
titles, and keys at 260 and 300 points in the app's dark scheme; screenshots are
saved to `/tmp/writertex-bibliography-260-dark.png` and
`/tmp/writertex-bibliography-300-dark.png` for visual inspection.

# Writing statistics checks

After a Debug build, run:

```sh
python3 Tests/run-checks.py <DerivedData> WritingStatisticsChecks.swift
```

Checks empty documents, soft breaks and blank paragraphs, Unicode, 250-word page
boundaries, clearing the old editor's text when a document is re-hosted, unsaved
edits, silent five-second refresh during continuous typing, and sampling
cancellation. The Writing inspector counts `.wrtx` manuscripts as the editor shows
them; pages are estimates rounded up at 250 words per page.

# CSV editing checks

Run the native grid checks:

```sh
python3 Tests/run-checks.py <DerivedData> CSVIntegrationChecks.swift
```

This opens the notebook's dataset grid in a temporary window. It verifies
double-click editing, the pending-edit flag, Return and Tab committing and
publishing the table, Escape cancellation, and serialization of quotes,
delimiters, line breaks, and empty cells. Requires a logged-in macOS GUI session.

# Manuscript document checks

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptFileChecks.swift
```

Treats a `.wrtx` as a document: a new manuscript opens untitled, choosing a
`.bib` is an undoable edit, saving writes the text and the bibliography link
together, a reopened manuscript cites the same file, removing a citation
rewrites the linked `.bib` in place, Undo/Redo unlink and relink it, Save As
retitles without reloading the editor, a `.bib` that is gone is named for
relinking and kept in the link, and manuscripts written before the link existed
open unchanged. The `.bib` lives in a temporary folder. It also mounts a new manuscript
window and a new notebook window and checks each shows its content and keeps
its session open. A bare hosting view runs `onAppear` even on an empty view,
which a document window does not, so a window that never makes its session
shows blank only in the running app: open File ▸ New Manuscript and File ▸ New
Analysis Notebook in a built app to confirm.

These run unsigned, so the App Sandbox is not in force: they cover the link and
its bookmark, not what the sandbox grants. Manual acceptance on a signed build:
File ▸ New Manuscript, choose a `.bib` from another folder in the References
inspector, save, quit, reopen from File ▸ Open Recent, and confirm the
citations load without choosing the file again. Repeat with File ▸ New Analysis
Notebook: import two CSVs, add a step, save, reopen.

CSV integration checks also exercise analysis snapshots: committing pending cell
edits, all versus filtered/sorted rows, stable source-row indices, numeric missing
and invalid values, duplicate headers, short records, type hints, snapshot
independence after edits, CSV serialization and closed-grid lifetime.

# Analysis notebook checks

The runtime runner takes a check file as an optional third argument. After the
same Debug build:

```sh
python3 Tests/run-checks.py <DerivedData> AnalysisIntegrationChecks.swift
```

These pin the statistics to the values R gives for the same data — sample SD,
type-7 quartiles, Pearson and tie-averaged Spearman, the t/F/chi-square/normal
distribution functions to twelve significant digits, `cor.test`, `chisq.test`,
`p.adjust`, `qt`, `t.test` in its one-sample, Welch, pooled and paired forms,
`summary(aov(y ~ f))` with Levene's test across the groups, the Type III two-way ANOVA from
`drop1(lm(y ~ a * b, contrasts = contr.sum), . ~ ., test = "F")` on unbalanced
cells (with the empty-cell and one-factor refusals and Levene across cells), and `summary(lm(y ~ x1 + x2))` with `confint` and
`anova` — and cover the missing
versus unusable distinction, the three missing policies, cross-tab totals and
exclusions, header drift and absent columns, snapshot fingerprints, notebook.json
round-tripping and validation, decoding a notebook written before significance
testing existed, the Markdown export, the export to a new manuscript (title and
step headings, native tables whose cells read as on screen, left-aligned text and
right-aligned number columns, failed and unrun steps, reopening the saved
`.wrtx`), Copy Result (WriterTex rich text, RTF and tab-separated rows on a
private pasteboard, pasting back as a heading and a native table), and cell resolution for the console
hand-off. The emitted R script is checked by executing it under `Rscript`, which
is skipped when R is not installed. Each expected constant carries the R
expression that produced it, so any of them can be regenerated with `Rscript`. The last blocks mount
`NotebookView` over an in-memory `.wrstatx` and run steps against its packaged
datasets; check that imports are copied in under unique names, that steps,
missing codes and imports undo and redo, that adding, deleting and renaming
rows and columns rewrites the CSV and re-points the steps that read it (undoably,
keeping the last column, and committing a cell still being typed in the grid
first), that each column's variable type is read from its cells (logical,
integer, numeric, ISO date, time and date-time, factor and character, with
the cases each rule refuses), that a chosen type overrides it, and that the read
types follow cell edits, Undo, the missing codes and removal, that Compute
evaluates formulas (precedence, functions, text, comparisons, missing and
non-number cells, division by zero, and each parse error) and Recode applies its
rules, both writing undoably into new or existing columns, that the compute sheet
and every step composer mount, that a step's roles fill in order, replace a
full one-variable role, trade places when a variable moves into a full role,
keep and reorder a list role's order, and know when a step has enough variables,
and that a notebook with several
datasets round-trips through a real package folder, reusing unchanged datasets.

# WriterTex manuscript checks

`ManuscriptTableChecks.swift` checks TextKit 1 Return navigation, appending one
row without replacing existing cells, double Return removing only that new empty
row, cancellation by typing or moving the caret, independent body paragraphs,
stable table height while typing outside, Undo/Redo, WRTX/DOCX output, and long
table scrolling. Backspace immediately after a table deletes the complete table
in one undoable edit; cell text and selected body text retain normal deletion.
It covers tables at EOF and before body text or a heading.

`MarkdownFormattingIntegrationChecks.swift` also checks explicit Block Quote
formatting from the paragraph-style control and Command-Shift-9: literal `>`
typing, continued quotes across empty paragraphs, native Backspace/Delete,
Body conversion, selection and inline formatting, pane ownership, Undo/Redo,
WRTX round trips, and Word Quote paragraph output.

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptEditorChecks.swift
```

Exercises the native editor's heading, bold, italic, strike, code and list typing
shortcuts, independent shortcut Undo/Redo, literal paste, UTF-16 ranges, native
RTFD storage with heading/list/block metadata, table alignment, embedded images,
empty/corrupt documents, plain-RTF manuscripts upgrading on save, and Word output with APA CSL citations and
bibliography. Fixtures use the runner's temporary home. Writes
`/tmp/writertex-manuscript-check.docx` for package validation. Reports insertion
and toolbar-update timings for 100-word and 100,000-word paragraphs; these are
local diagnostics, not rendering benchmarks or hardware-independent thresholds.

`.wrtx` is a versioned binary property list containing native RTFD and semantic
style runs. WriterTex never writes Markdown, and `.md` files don't open. Plain clipboard text contains the visible text;
the private rich clipboard representation preserves WriterTex styles and images.

The manuscript checks also exercise live Appearance foreground changes through
`NSTextView.textColor`, caret and typing colors, reopening with the current theme,
and preservation of selection, fonts, Undo and the saved document's clean state.
Dollar delimiters remain ordinary text; no LaTeX-specific spans are produced.

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptCitationChecks.swift
```

Checks native citation links on load and edits, RTFD round trips, accent rendering
after foreground changes, citation menu actions, code/external-link exclusions,
and removal of internal link URLs from plain text and export. Captures the native
text view in `/tmp/writertex-citation-theme.png` and checks its accent pixels.

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptDisplayChecks.swift
```

Exercises shrinking/growing drag selections and selection-to-caret transitions on prose and a table/heading
fixture over a transparent gradient, at normal and fractional view positions and
widths. Reads the current AppKit backing layer without requesting a fresh text
draw, checks that selection pixels disappear, and verifies that display work
does not modify paragraph styles, content or Undo. Also inserts and deletes
paragraph breaks between native WriterTex headings and sparse body text, comparing the incremental
backing pixels with a fresh redraw at three widths. Fractional native line spacing
is retained throughout; no point-grid quantization is required.

Live-window acceptance is also required: in a native `.wrtx` document, place a
single-line H3 and a short body paragraph below an H1. Press Return at the end
of the H1, then at the end of the H3. Smaller text must remain visible and move
down immediately, before any scrolling or resizing. Repeat with Undo and
Backspace. A backing-layer snapshot can miss stale pixels in the live window;
inspect the actual on-screen result. Also drag a selection across several wrapped
lines, shrink it, move it elsewhere, and clear it. No highlight edges may remain
before scrolling. Selection invalidations cover their native dirty rectangles
plus the antialiased backing-pixel fringe. Text edits repaint the viewport after
the edit, allowing layout of visible text. Do not widen a no-layout invalidation
to the viewport: AppKit may clear text that has not been laid out yet. Repeated
Return/Backspace in a long document must not flash the text. Paragraph metrics
remain native throughout.

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptScrollChecks.swift
```

Checks typing into a short native manuscript, then revealing text throughout
short prose, a 200-row table, and roughly 50,000 words before and after narrowing
the window. Native layout may be deferred; each scroll target must be visible
and contained within the document view. Scrolling/resizing must preserve text,
attributes, selection and Undo. Reported durations measure native setup and
programmatic reveals, not trackpad frame rate or compositor behavior.

# Manuscript spacing checks

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptSpacingChecks.swift
```

Checks native line-height multipliers and paragraph spacing without fixed minimum
line heights, preservation of legacy spacing defaults, native double spacing in
manuscript exports, and Word's `w:line`/`w:before`/`w:after` values.

# Manuscript responsiveness checks

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptResponsivenessChecks.swift
```

On a 150k-character manuscript: citation links are not stored and are rebuilt
on opening (AppKit's RTF reader otherwise resolves each through the system data
detectors, which can block on the spell checker), the editor has no layout
delegate (it would cost TextKit its fast relayout below a new paragraph). AppKit tracks the text view's
width with fixed native insets through wide/narrow resizes and zero-width host
collapses. Text and caret positions must agree. Prints stall and open timings.

# Manuscript click checks

```sh
python3 Tests/run-checks.py <DerivedData> ManuscriptClickChecks.swift
```

Clicks the workspace split view's editor with real mouse events, with both
columns hidden, at wide and narrow window sizes, and checks that each click
selects the character it points at and draws the caret there. The editor uses
native width tracking and fixed text-container insets.
Create `/tmp/writertex-fullscreen` first
to also check real full screen, which takes over the screen for a few seconds.
