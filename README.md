# projectbuilder

Scaffold a data-analysis project in Stata with one command: a raw-data
folder, an analytic-data folder, an output folder, a documentation folder,
and a numbered do-file pipeline. If the data already exists, `projectbuilder`
also copies it in, converts it, appends it into one analytic file, and writes
a documentation page. If the data comes later, scaffold now and rerun with
`rebuild` on every refresh.

Companion package to *Applied Program Evaluation Using Stata* (Booth & Teas).
It runs anywhere: no organization-specific paths, no template folders, no shell
calls, and the same behavior on macOS, Windows, and Linux.

## Install

From GitHub:

```stata
net install projectbuilder, from("https://raw.githubusercontent.com/ericabooth/projectbuilder-stata-public/main/") replace force
help projectbuilder
```

`net install` copies the command and its help file. The test battery ships as an
ancillary file, so fetch it separately if you want to run it:

```stata
net get projectbuilder, from("https://raw.githubusercontent.com/ericabooth/projectbuilder-stata-public/main/") replace
```

Requires Stata 16.0 or newer. No hard dependencies.


<img width="2400" height="1260" alt="projectbuilder_srctag_suite" src="https://github.com/user-attachments/assets/f4aa142e-d63d-46b7-a805-247bac2fc10d" />

## Quick start

**Workflow A — the data already exists.** Point `data()` at a folder of files
(and/or `url()` at a source address). `projectbuilder` copies the files into
`01_raw/` and builds the documentation. The conversion into
`01_raw/_converted/` requires `convertanything`, and the append into
`02_cleaned/<project>_analytic.dta` requires `combineall`; neither is installed
by default, and the run prints the install command for whichever is missing.

```stata
cd "~/projects"
projectbuilder CountyBudgets,                                     ///
    data("~/Desktop/budget_drop")                                ///
    description("County budget CSVs, one row per dept per FY")   ///
    topic("local government, budgets") publicfacing(unsure)      ///
    timeline("annual") outcomes(total_budget) over(year dept) descsave
```

Check that `02_cleaned/CountyBudgets_analytic.dta` exists before running
`300_labels.do`, which opens it. If the optional companions were missing, the
file is not there yet and `300_labels.do` stops with `r(601)`.

**Workflow B — data later.** Scaffold now with no `data()`/`url()`, drop files
into `01_raw/` when they arrive, then rebuild. Every refresh is another
`rebuild`; it never overwrites a do-file you have edited unless you add
`replace`:

```stata
projectbuilder VendorFeed, description("Monthly vendor extract")
* ... later, after dropping files into VendorFeed/01_raw/ ...
projectbuilder VendorFeed, rebuild
```

This creates:

```
VendorFeed/
├── 01_raw/                raw source files (write-once)
│   ├── _archive/
│   └── _converted/        one .dta per raw file (convertanything)
├── 02_cleaned/            <project>_analytic.dta lives here
│   └── _archive/
├── 03_output/             logs, tables, exhibits
│   └── _archive/
├── _code/
│   ├── 000_control.do         every path in one place; run-all block
│   ├── 100_data_download.do
│   ├── 200_data_management.do convertanything -> combineall
│   ├── 300_labels.do
│   ├── 400_data_profiler.do
│   ├── 500_aggregation.do
│   ├── 600_analysis.do
│   └── _archive/
├── _documentation/
│   ├── index.do             webdoc2 source
│   ├── _runall.do           renders website/index.html
│   ├── _project_meta.txt    recorded metadata, read back on rebuild
│   ├── Readme.md
│   ├── website/index.html
│   └── _archive/
└── _archive/
```

`000_control.do` pins the language version, stamps `$root` with the absolute
path of the new folder (one loudly commented line to edit if the project moves),
derives `$raw`, `$converted`, `$cleaned`, `$output`, `$code`, and `$docs` from
it, and ends with a run-all block over the numbered pipeline. The pin is
`version 16.0`, this package's own floor, not the release of the Stata that
generated the file, so the control file still runs for a teammate on an older
Stata. Raise it by hand if the project needs newer syntax.

## Recorded metadata

`description()`, `url()`, `topic()`, `publicfacing()`, `timeline()`,
`othernotes()`, `outcomes()`, `over()`, and the creation date are written to
`_documentation/_project_meta.txt` as `key=value` lines and read back on every
later call. A bare `rebuild` therefore keeps the metadata recorded at scaffold
time instead of resetting it to placeholders; an option given on the current
call replaces the recorded value. The `Created` row is the first-scaffold date
and is not restamped by a rebuild; the build date and time appear in the footer
of `index.html` and `Readme.md`.

`_documentation/index.do` is guarded like the numbered do-files, so a `rebuild`
without `replace` leaves it as written. Because it and the regenerated
`index.html` both come from the same recorded metadata, they agree after a
rebuild unless you edit one of them by hand.

## Optional dependencies

None are required. Each is detected with `capture which`; if it is missing,
the generated do-file still contains the call (a working example), the
automatic pass skips that step, and a one-line note names the install command.

| Package | What it adds | Install |
|---------|--------------|---------|
| `convertanything` | bulk-convert `01_raw/` to `.dta` in `01_raw/_converted/` | `net install convertanything, from("https://raw.githubusercontent.com/ericabooth/convertanything-stata-public/main/")` |
| `combineall` | append/merge the converted files into the analytic file | `net install combineall, from("https://raw.githubusercontent.com/ericabooth/combineall-stata-public/main/")` |
| `descsave` | codebook (.dta plus .xlsx) from `300_labels.do` | `ssc install descsave` |
| `srctag` / `srcfind` | tag and search each variable's source lineage | `net install srctag, from("https://raw.githubusercontent.com/ericabooth/srctag-stata-public/main/")` |
| `datadictionary` | codebook workbook; harvests srctag's tags | `ssc install datadictionary` |
| `webdoc2` | render a richer `index.html` | `ssc install webdoc`, then `net install webdoc2` (author's GitHub) |

`webdoc2` needs no extra step: projectbuilder writes a self-contained
`header_fallback.html` into every project's `_documentation/` on every run,
and the render stages it automatically when webdoc2's own themed
`header.html` is not installed. (Before v2.1.0 this took a manual `net get`
plus an adopath move; that step is gone.)

Run `projectbuilder check` to see every companion's status in one table,
with clickable install commands.

Three of the companions form one provenance chain with projectbuilder:
`combineall` stamps `char[source]` on every variable it harmonizes while
building the analytic file, the generated `300_labels.do` invites
`srctag` to add what those stamps lack (agency, vintage, URL), and
`datadictionary` harvests it all into a codebook workbook a client can
read without Stata. The srctag package's help files document the full
chain (`help srctag`, section "The ecosystem").

When `webdoc2` is absent, `projectbuilder` writes a plain but complete
`index.html` and `Readme.md` directly, so the documentation always exists.

## Stored results

`projectbuilder` is `rclass` and stores:

- `r(project)` — project label (slashes become underscores)
- `r(path)` — absolute path of the project folder
- `r(nraw)` — number of files in `01_raw/`
- `r(nconverted)` — number of `.dta` files in `01_raw/_converted/`
- `r(rebuilt)` — `1` if this call refreshed an existing project, else `0`

## Your data in memory

`projectbuilder` leaves the dataset in memory exactly as it found it. The
automatic pass does load data — `convertanything` runs with `clear`, and
`combineall` does its own `use` and `save` — so the command wraps that pass in
`preserve`. Scaffolding or refreshing in the middle of an analysis session does
not cost you your data. `noautoconvert` skips the pass, and with it the
`preserve`.

## Testing

`test_projectbuilder.do` scaffolds into a temporary directory and checks both
workflows, the rebuild idempotence and edit-preservation guarantee, metadata
preservation across a rebuild, the seeded-`_converted/` combine path, the
clobber refusal (602), name and option validation (198), nesting, HTML escaping,
and the generated control file. It runs every example printed in the help file
and the clickable *Try it now* walkthrough, so the documentation cannot drift
from the code, and it runs all seven generated do-files end to end, so the
pipeline the package writes cannot break unnoticed. Synthetic data only;
nothing is committed.

If you installed rather than cloned, get the file first with `net get
projectbuilder` (see [Install](#install)); it lands in the current directory.

The test finds the package itself: it uses the first of an argument, an
existing `$pkgroot`, the current directory, or `findfile projectbuilder.ado`.
Run it from the package folder with no arguments, or from any scratch directory
by naming the package folder:

```
stata-mp -b do test_projectbuilder.do
stata-mp -b do test_projectbuilder.do "/path/to/projectbuilder-stata-public"
```

## Changes in 2.1.0

- **Self-contained documentation render.** projectbuilder now writes
  `header_fallback.html` into every project, and the generated `_runall.do`
  stages it under the name webdoc2's `wdinit` looks for whenever no
  `header.html` is installed — then removes it after the render. The old
  requirement to `net get webdoc2` and move its ancillary `header.html`
  onto the adopath is gone; a webdoc2 render succeeds with nothing
  installed beyond `webdoc` and `webdoc2` themselves. The fallback header
  has no CDN links, so rendered pages read correctly offline.
- **`projectbuilder sitebuild`** scans a base folder for projects and
  writes `projects_index.html` + `projects_index.md`: one catalog page
  linking every project's documentation site with its recorded metadata.
  A folder of isolated project sites becomes a browsable portfolio.
- **`projectbuilder check`** prints one table covering every optional
  companion — installed or missing, what it adds, and the exact install
  command, clickable — replacing the install hints that were scattered
  across five different moments of a run. Stores `r(missing)` and
  `r(nmissing)` for scripts.
- **Per-stage run log.** The generated control file's run-all block times
  each pipeline stage and appends a line to `_documentation/run_log.txt`;
  a failing stage is logged with its return code before the failure is
  re-raised.
- **Raw-file change report.** Every run records each raw file's `checksum`
  in `_project_meta.txt`; a rebuild compares and prints how many raw files
  are new, changed, and unchanged, naming the changed ones.
- `sitebuild` and `check` are reserved words and cannot be used as project
  names.

## Changes in 2.0.1

- The dataset in memory is preserved across the automatic convert/combine pass.
  It used to be silently replaced by the converted file.
- The generated `400_data_profiler.do` runs under the `version 16.0` pin that
  `000_control.do` sets. It used to emit Stata 17 `table, statistic()` syntax
  and stop with r(198).
- `builddocs` renders. The generated `_runall.do` now carries a literal
  documentation path instead of `$docs`, which is undefined at the point
  `projectbuilder` runs that file.
- A backtick in any option value is refused up front, naming the option. It
  used to abort partway through and leave a half-built folder that blocked the
  corrected re-run with 602.
- A tilde in a value survives into the generated files. `url(".../~Dave/...")`
  used to be written out as `.../$ave/...`.
- A `$` or a backtick recorded in `_project_meta.txt` survives a rebuild.
- A relative `path()` is resolved, so `r(path)` and `$root` are absolute as
  documented.
- Failures are reported rather than swallowed: files `data()` could not copy, a
  base that exists but is not writable, and directories that cannot be listed.
- Directory tests use Mata's `direxists()` in place of `confirm file dir/.`.

First-run clarity, from watching new readers work through the help:

- The "Next steps" block no longer tells you to review an analytic file that was
  never created. Without the optional companions — the default state — it now
  says the file is missing and gives the two ways to get one.
- A `data()` folder that does not exist is reported as an error rather than a
  passing note, so an empty project no longer looks like a success.
- `rebuild` on a project that does not exist still scaffolds one, which is what
  makes it safe in a scheduled script, but it now says that is what it did. A
  mistyped name used to look like a successful refresh. `r(rebuilt)` is `1` only
  when an existing project was refreshed.
- The help gained a Quick start, and Workflow A now creates the folder its
  example reads from, so its first worked example runs as printed.
- The Options section documents the `des()` / `desc` abbreviation split and the
  fact that options changing a guarded do-file need `replace` to take effect.

What the command prints now matches the help around it:

- The `Rerun:` hint is copy-pasteable. It used to drop the `path()` you built
  with, so pasting it from another directory made a second empty project, and
  it printed a name with spaces unquoted, which the command itself rejects.
- The console said "Method B" where the help says Workflow B.
- `descsave` is recorded in `_project_meta.txt` like every other option. A bare
  rebuild used to report it as `no`, and `rebuild replace` deleted the codebook
  call it had written.
- A bare rebuild says when `outcomes()`/`over()`/`descsave` were recorded but
  `_code/` was left alone, and `replace` says when it overwrote your edits.
  Nothing is archived automatically; the `_archive/` folders are yours.
- `builddocs` runs the render quietly and reports one line either way. It used
  to echo the whole of `_runall.do` and end in a bare `r(601)` that read as a
  crash when it was caught.
- `publicfacing()` trims surrounding spaces; `othernotes()` is echoed in the
  summary like the other metadata; `description()` reaches the header of
  `000_control.do`, which the help had claimed all along.
- `Readme.md` gets Markdown escaping rather than HTML: `R&D` stayed `R&amp;D`
  in a file people read raw.
- Warnings when the converted count does not match the raw count — same-stem
  files overwriting each other, or stale output from a raw file since deleted.
- `path()` naming an existing file says so instead of "not found".

And one defect in the code the package *generates*, found by running the
generated pipeline rather than only inspecting it:

- `300_labels.do` called `descsave using "<file>.xlsx", ... replace`. `descsave`
  has no top-level `replace`, and its `using` names the file to *describe*, not
  the output — so on any machine where `descsave` was installed the file stopped
  with `r(198)`. Everyone else hit the "not installed" branch, which is why it
  went unseen. It now calls `descsave, list(...) saving("<file>.dta", replace)`
  and exports that to `.xlsx` with `export excel`, wrapped in `preserve` so the
  analytic file is still loaded afterwards. The test battery now runs all seven
  generated do-files instead of only `000_control.do`.

An independent clean-room pass then found two more, both in `builddocs`:

- The webdoc2 render landed in `_documentation/index.html`, while the run's
  `Docs:` pointer, the help, and the README all name
  `_documentation/website/index.html` — so the page you were sent to was always
  the built-in fallback, never the rendered one. The generated `_runall.do` now
  copies the rendered page into `website/`.
- `builddocs` reported `rendered.` even when webdoc2 had failed, because the
  generated `_runall.do` swallowed the error and always returned 0. It now
  propagates the return code, so a failure is reported as one.

Also: a tilde in the *filename* part of `url()` was still corrupted on its way
into `100_data_download.do` (`.../~Dataset.csv` became `$raw/$ataset.csv`, which
downloads into a hidden `.csv`); the `Rerun:` hint now always carries `path()`,
so it is portable even for a project built in the current directory; the `.pkg`
description no longer promises an analytic file that a companion-free install
does not produce; and the README says how to obtain the test file after a
`net install`.

## Authors

Eric A. Booth, Sr Researcher, Texas 2036 (eric.a.booth@gmail.com)

Elizabeth Teas, Sr Research Scientist, Far Harbor, LLC (elizabeth@farharbor.com)

Support: eric.a.booth@gmail.com

## License

MIT. See [LICENSE](LICENSE).
