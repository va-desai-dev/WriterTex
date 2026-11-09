# Documents

WriterTex is a document app. Each window is one document, opened, saved and
recovered by macOS like any other: Open Recent, Save As, Duplicate, Rename,
Move To, Revert To, autosave and Versions all come from the system. There are
two kinds, and neither shows the other's tools.

| Kind | File | Holds |
| :-- | :-- | :-- |
| Manuscript | `Name.wrtx` | The text, and a link to the one `.bib` it cites |
| Analysis notebook | `Name.wrstatx` | Steps, missing-value codes, and every CSV they read |

## Manuscripts and their bibliography

A `.wrtx` is a single file: the manuscript's native rich text plus the styles
RTF cannot express (heading levels, code and citation spans). A manuscript
cites from exactly one `.bib`, which can be anywhere on the Mac. Choose it, or
create a new one, from the References inspector; choosing it is an undoable
edit that is saved with the manuscript.

The `.bib` is linked, never copied, so the same bibliography can serve several
manuscripts and stays usable in other tools. Citation edits and Safari captures
from CiteTex are written straight into it. The link stores a security-scoped
bookmark, so on this Mac the file reopens without asking again, plus its last
known path. On another Mac the bookmark means nothing: the inspector names the
missing file and offers Locate….

## Notebooks and their datasets

A `.wrstatx` is a package, a folder Finder shows as one file:

```
Name.wrstatx/
  notebook.json      steps and missing-value codes
  Datasets/
    survey.csv       each table the steps read
```

Importing a CSV copies it in, giving a taken name a number rather than
replacing a table, so the notebook opens the same wherever it is sent. A
notebook holds up to 64 datasets of up to 32 MB each. Steps name their table by
file name inside `Datasets`. Removing a dataset keeps the steps that read it;
they report it missing when run. Rows and columns are added and deleted from
the dataset's edit menu at the selected cell, and columns are renamed, added and
deleted in the inspector. Steps follow a column that moves or is renamed; a step
reading a deleted column reports it missing rather than reading its neighbour.
Each column's variable type is read from its cells, skipping blanks and missing
codes: only 0/1, yes/no or true/false (any case) is logical; whole numbers are
integer and other numbers numeric; ISO 8601 values are a date, time or
date-time; text repeating at most 50 levels, each used about twice, is a factor;
anything else, or a column with no values, is character. Read types follow the
cells and missing codes and are not saved. A type chosen in a column's popover
overrides the read one and is saved with the notebook; Automatic goes back to it.
Compute Variable writes an Excel-style formula's value for every case into a
new or existing column: `+ - * / ^`, comparisons (1 or 0), `&` to join text,
`"text"`, bare one-word headers or `[Any Header]`, and ABS, SQRT, EXP, LN, LOG10,
INT, ROUND, SUM, MEAN/AVERAGE, MIN, MAX, IF, AND, OR, NOT and ISBLANK. Missing
follows SPSS: arithmetic on a blank or missing code is blank, while SUM, MEAN,
MIN and MAX skip it. Recode Variable maps values, numeric ranges (open at either
end), missing values and everything else to a new value, a blank or the old
value, first rule first, into the same variable or a new one. Both preview the
first rows, write into the CSV, and undo in one step.
A step's sheet lists the variables on the left and the step's roles on the
right (Outcome, Factor, Predictors, Variables…), each taking one variable or a
list. A click adds a variable to the highlighted role, which then moves on once
full; clicking a picked variable takes it out. Variables can be dragged into any
role, reordered within a list role, moved between roles (into a full role,
they trade places), or dragged back to the list to take them out. A variable
fills one role at most, and a list role's order
is the order the step reads and reports them in.
Two-Way ANOVA crosses two factors: every cell's N, mean and SD, both main
effects and their interaction with Type III sums of squares (sum-to-zero coding,
as SPSS reports; R's `drop1`, not `anova()`), partial η², and Levene's test
across the cells. Every combination of levels needs at least one case. The
step is stored as a factorial ANOVA over a list of factors, so more factors need
only a wider role.
Every change to steps, codes or datasets is undoable. Results are recomputed and never saved; Export Results writes them to
a new `.wrtx` manuscript, with each step as a heading and each result table as a
native table, and opens it in its own window, or as a Markdown report. Each
step's Copy button puts its result on the pasteboard to paste into a manuscript
as a native table, into another app as RTF, or into a spreadsheet as tab-separated rows. Export R
Script writes the steps as R that reads the datasets inside the saved package.

## Sandbox

The App Sandbox grants WriterTex only the files the user picks. Documents
themselves are handled by the system. A linked `.bib` is written in place,
because the sandbox grants the file but not its folder, where an atomic save
would need to put its temporary copy. Exports ask for their destination.
