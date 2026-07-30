* test_projectbuilder.do -- test battery for projectbuilder v2.0.0
* Run from the package folder, or from any scratch directory by naming the
* package folder:
*     stata-mp -b do test_projectbuilder.do
*     stata-mp -b do test_projectbuilder.do "/path/to/projectbuilder-stata-public"
* All paths live in globals set here; synthetic data only (no committed
* .dta/.log).  Judge success by the absence of r(NNN); and failed asserts.

* ---- where the package lives ------------------------------------------
* Read the caller's overrides BEFORE -clear all-, which drops globals.
* Resolution order, first hit wins:
*   1. an argument passed to this do-file
*   2. a global $pkgroot the caller set beforehand
*   3. the current directory, if projectbuilder.ado sits in it
*   4. -findfile-, which searches the ado-path
local argroot `"`1'"'
local preroot `"$pkgroot"'

clear all
set more off
version 16.0
set seed 20260707

global pkgroot `"`argroot'"'
if `"$pkgroot"' == "" global pkgroot `"`preroot'"'
if `"$pkgroot"' == "" {
    capture confirm file `"`c(pwd)'/projectbuilder.ado"'
    if !_rc global pkgroot `"`c(pwd)'"'
}
if `"$pkgroot"' == "" {
    capture findfile projectbuilder.ado
    if !_rc {
        local fp `"`r(fn)'"'
        local s = max(strrpos(`"`fp'"', "/"), strrpos(`"`fp'"', "\"))
        if `s' > 1 global pkgroot = substr(`"`fp'"', 1, `s' - 1)
    }
}
if `"$pkgroot"' == "" {
    di as err "test_projectbuilder: cannot locate projectbuilder.ado."
    di as err `"  Pass the package folder:  do test_projectbuilder.do "/path/to/pkg""'
    exit 601
}
confirm file "$pkgroot/projectbuilder.ado"
di as text `"test_projectbuilder: pkgroot = $pkgroot"'

* Prepend so this source copy wins over any older installed copy in PLUS.
adopath ++ "$pkgroot"

* ---- fresh scratch tree for this run ----------------------------------
tempfile tbase
global work "`tbase'_pbtest"
mkdir "$work"

* helper: load a text file one line per obs into v1 (line-oriented read)
capture program drop loadlines
program define loadlines
    import delimited using `0', clear delimiters("`=char(1)'", asstring) ///
        varnames(nonames) bindquote(nobind) encoding("utf-8")
end

* helper: write one line to a file, turning ~B into a literal backtick, so
* this do-file can emit an ado-file that itself uses local macros.
capture program drop wline
program define wline
    gettoken fh 0 : 0
    file write `fh' (subinstr(`0', "~B", char(96), .)) _n
end

di as text "{hline 70}"
di as text "TEST a1: Method B -- scaffold only, every folder and file exists"
di as text "{hline 70}"
projectbuilder Demo, path("$work")
assert `"`r(project)'"' == "Demo"
assert `"`r(path)'"'    == `"$work/Demo"'
assert r(nraw)       == 0
assert r(nconverted) == 0
assert r(rebuilt)    == 0

foreach d in 01_raw 01_raw/_archive 01_raw/_converted ///
             02_cleaned 02_cleaned/_archive ///
             03_output 03_output/_archive ///
             _code _code/_archive ///
             _documentation _documentation/_archive _documentation/website ///
             _archive {
    confirm file "$work/Demo/`d'/."
}
foreach f in 000_control.do 100_data_download.do 200_data_management.do ///
             300_labels.do 400_data_profiler.do 500_aggregation.do    ///
             600_analysis.do {
    confirm file "$work/Demo/_code/`f'"
}
foreach f in index.do _runall.do Readme.md _project_meta.txt {
    confirm file "$work/Demo/_documentation/`f'"
}
confirm file "$work/Demo/_documentation/website/index.html"

* 01_raw must be empty (no files; subfolders don't count)
local rl : dir "$work/Demo/01_raw" files "*"
assert `: word count `rl'' == 0

di as text "{hline 70}"
di as text "TEST a2: edit a code file, drop data, rebuild -> convert/combine/docs"
di as text "{hline 70}"

* sentinel line appended to a code file the 'user' has edited
tempname sfh
file open `sfh' using "$work/Demo/_code/000_control.do", write text append
file write `sfh' _n "* SENTINEL-KEEP-ME-4711" _n
file close `sfh'

* two synthetic CSVs dropped into 01_raw by hand
sysuse auto, clear
quietly export delimited using "$work/Demo/01_raw/auto_part1.csv", replace
keep make price mpg
quietly export delimited using "$work/Demo/01_raw/auto_part2.csv", replace

projectbuilder Demo, path("$work") rebuild
assert r(nraw)    == 2
assert r(rebuilt) == 1
confirm file "$work/Demo/_documentation/website/index.html"

* the rebuilt documentation mentions both raw files
loadlines "$work/Demo/_documentation/website/index.html"
quietly count if strpos(v1, "auto_part1.csv")
assert r(N) >= 1
quietly count if strpos(v1, "auto_part2.csv")
assert r(N) >= 1

* rebuild WITHOUT replace must NOT overwrite the edited code file
loadlines "$work/Demo/_code/000_control.do"
quietly count if strpos(v1, "SENTINEL-KEEP-ME-4711")
assert r(N) == 1

di as text "{hline 70}"
di as text "TEST a3: rebuild WITH replace overwrites the code file"
di as text "{hline 70}"
projectbuilder Demo, path("$work") rebuild replace
loadlines "$work/Demo/_code/000_control.do"
quietly count if strpos(v1, "SENTINEL-KEEP-ME-4711")
assert r(N) == 0

di as text "{hline 70}"
di as text "TEST b: Method A -- data() copies a folder of files into 01_raw/"
di as text "{hline 70}"
mkdir "$work/_src2"
sysuse auto, clear
quietly export delimited using "$work/_src2/src_a.csv", replace
keep make foreign
quietly export delimited using "$work/_src2/src_b.csv", replace
projectbuilder Demo2, path("$work") data("$work/_src2") ///
    description("two synthetic CSVs")
assert r(nraw) == 2
confirm file "$work/Demo2/01_raw/src_a.csv"
confirm file "$work/Demo2/01_raw/src_b.csv"

di as text "{hline 70}"
di as text "TEST c: clobber guard -- rerun without rebuild -> _rc==602"
di as text "{hline 70}"
capture noisily projectbuilder Demo, path("$work")
assert _rc == 602
confirm file "$work/Demo/_code/000_control.do"

di as text "{hline 70}"
di as text "TEST d: leaf/option validation -> _rc==198"
di as text "{hline 70}"
capture noisily projectbuilder "../evil", path("$work")
assert _rc == 198
capture noisily projectbuilder EvilPF, path("$work") publicfacing(maybe)
assert _rc == 198

di as text "{hline 70}"
di as text "TEST e: Source/Subsource nesting"
di as text "{hline 70}"
projectbuilder Agency/Extract, path("$work")
assert `"`r(project)'"' == "Agency_Extract"
assert `"`r(path)'"'    == `"$work/Agency/Extract"'
confirm file "$work/Agency/Extract/_code/000_control.do"
confirm file "$work/Agency/Extract/_documentation/website/index.html"

di as text "{hline 70}"
di as text "TEST f: a stray extra token is rejected -> _rc==198"
di as text "{hline 70}"
capture noisily projectbuilder E1 E2, path("$work")
assert _rc == 198
capture confirm file "$work/E1 E2/."
assert _rc != 0
* a quoted name containing a space is still a single, legal name
projectbuilder "Two Words", path("$work")
assert `"`r(project)'"' == "Two Words"
confirm file "$work/Two Words/_code/000_control.do"

di as text "{hline 70}"
di as text "TEST g: a bare rebuild PRESERVES the recorded metadata"
di as text "{hline 70}"
projectbuilder Meta, path("$work") description("desc one") topic("t") ///
    publicfacing(yes) timeline("annual") othernotes("from the county") ///
    outcomes(price mpg) over(foreign)
confirm file "$work/Meta/_documentation/_project_meta.txt"
copy "$work/Meta/_documentation/website/index.html" "$work/meta_index_before.html"
copy "$work/Meta/_documentation/Readme.md"          "$work/meta_readme_before.md"

projectbuilder Meta, path("$work") rebuild
assert r(rebuilt) == 1

* the placeholders must NOT have replaced the recorded values
loadlines "$work/Meta/_documentation/website/index.html"
quietly count if strpos(v1, "<p>desc one</p>")
assert r(N) == 1
quietly count if strpos(v1, "<td>t</td>")
assert r(N) == 1
quietly count if strpos(v1, "<td>annual</td>")
assert r(N) == 1
quietly count if strpos(v1, "<td>from the county</td>")
assert r(N) == 1
quietly count if strpos(v1, "add a one-line description")
assert r(N) == 0
quietly count if strpos(v1, "(not recorded)")
assert r(N) == 0

loadlines "$work/Meta/_documentation/Readme.md"
quietly count if strpos(v1, "| Topic | t |")
assert r(N) == 1
quietly count if strpos(v1, "(not recorded)")
assert r(N) == 0

* line-by-line diff: only the build-time footer may differ
loadlines "$work/meta_index_before.html"
gen long _ln = _n
tempfile before_html
quietly save `before_html'
loadlines "$work/Meta/_documentation/website/index.html"
gen long _ln = _n
rename v1 v1_after
quietly merge 1:1 _ln using `before_html'
assert _merge == 3
quietly count if v1_after != v1 & !strpos(v1, "Built ")
assert r(N) == 0

loadlines "$work/meta_readme_before.md"
gen long _ln = _n
tempfile before_md
quietly save `before_md'
loadlines "$work/Meta/_documentation/Readme.md"
gen long _ln = _n
rename v1 v1_after
quietly merge 1:1 _ln using `before_md'
assert _merge == 3
quietly count if v1_after != v1 & !strpos(v1, "Built ")
assert r(N) == 0

* -rebuild replace- keeps the recorded outcomes()/over() in the profiler
projectbuilder Meta, path("$work") rebuild replace
loadlines "$work/Meta/_code/400_data_profiler.do"
quietly count if strpos(v1, `"local outcomes "price mpg""')
assert r(N) == 1
quietly count if strpos(v1, `"local over     "foreign""')
assert r(N) == 1

* an option given on the current call still wins over the recorded value
projectbuilder Meta, path("$work") rebuild topic("procurement")
loadlines "$work/Meta/_documentation/website/index.html"
quietly count if strpos(v1, "<td>procurement</td>")
assert r(N) == 1
quietly count if strpos(v1, "<p>desc one</p>")
assert r(N) == 1

di as text "{hline 70}"
di as text "TEST h: the generated control file pins the package's version floor"
di as text "{hline 70}"
loadlines "$work/Demo2/_code/000_control.do"
quietly count if strpos(v1, "version 16.0")
assert r(N) == 1

di as text "{hline 70}"
di as text "TEST i: metadata is HTML-escaped in index.html and Readme.md"
di as text "{hline 70}"
projectbuilder Esc, path("$work") description("R&D <b>bold</b>") ///
    topic("a&b <tag>") othernotes("left|right")
loadlines "$work/Esc/_documentation/website/index.html"
quietly count if strpos(v1, "<td>a&amp;b &lt;tag&gt;</td>")
assert r(N) == 1
quietly count if strpos(v1, "<p>R&amp;D &lt;b&gt;bold&lt;/b&gt;</p>")
assert r(N) == 1
quietly count if strpos(v1, "<td>a&b <tag></td>")
assert r(N) == 0
loadlines "$work/Esc/_documentation/Readme.md"
quietly count if strpos(v1, "| Topic | a&amp;b &lt;tag&gt; |")
assert r(N) == 1
quietly count if strpos(v1, "| Other notes | left\|right |")
assert r(N) == 1

di as text "{hline 70}"
di as text "TEST j: a seeded 01_raw/_converted/ drives the combine branch"
di as text "{hline 70}"
* convertanything and combineall are optional and usually absent, so the
* shipped battery never reached the code path that fires when there IS
* something converted to combine.  Seed 01_raw/_converted/ by hand to reach
* it: r(nconverted) is non-zero for the first time here.
projectbuilder Seeded, path("$work") description("seeded converted fixture")
sysuse auto, clear
quietly export delimited using "$work/Seeded/01_raw/auto_raw.csv", replace
keep make price mpg foreign
quietly save "$work/Seeded/01_raw/_converted/part1.dta", replace
quietly save "$work/Seeded/01_raw/_converted/part2.dta", replace

projectbuilder Seeded, path("$work") rebuild
assert r(nraw)       == 1
assert r(nconverted) >= 2
loadlines "$work/Seeded/_documentation/website/index.html"
quietly count if strpos(v1, "part1.dta")
assert r(N) >= 1
quietly count if strpos(v1, "part2.dta")
assert r(N) >= 1

* Now put a minimal stand-in for -combineall- on the ado-path, so the call
* projectbuilder makes is actually executed and the analytic file it names
* is actually produced.  The stand-in accepts the same option signature.
mkdir "$work/_stubado"
tempname cfh
file open `cfh' using "$work/_stubado/combineall.ado", write text replace
wline `cfh' `"*! test stand-in for combineall (test_projectbuilder.do)"'
wline `cfh' `"program define combineall"'
wline `cfh' `"    version 16"'
wline `cfh' `"    syntax using/ [, CMethod(string) DIRectory(string) FILEtype(string) REPLACE ]"'
wline `cfh' `"    local fl : dir "~Bdirectory'" files "*.~Bfiletype'""'
wline `cfh' `"    local k = 0"'
wline `cfh' `"    foreach f of local fl {"'
wline `cfh' `"        local ++k"'
wline `cfh' `"        if ~Bk' == 1 use "~Bdirectory'/~Bf'", clear"'
wline `cfh' `"        else append using "~Bdirectory'/~Bf'", force"'
wline `cfh' `"    }"'
wline `cfh' `"    if ~Bk' == 0 {"'
wline `cfh' `"        di as err "combineall stand-in: nothing to combine""'
wline `cfh' `"        exit 601"'
wline `cfh' `"    }"'
wline `cfh' `"    save "~Busing'", replace"'
wline `cfh' `"end"'
file close `cfh'

adopath ++ "$work/_stubado"
capture program drop combineall
projectbuilder Seeded, path("$work") rebuild
assert r(nconverted) >= 2
confirm file "$work/Seeded/02_cleaned/Seeded_analytic.dta"
use "$work/Seeded/02_cleaned/Seeded_analytic.dta", clear
assert _N >= 148              // 74 observations from each seeded .dta
capture program drop combineall
adopath - "$work/_stubado"

di as text "{hline 70}"
di as text "TEST k: the generated 000_control.do runs; its globals are real dirs"
di as text "{hline 70}"
* stash test state: the control file runs -clear all-, which drops globals,
* programs, and adopath additions.
local W  "$work"
local PK "$pkgroot"
do "$work/Demo2/_code/000_control.do"
assert `"$root"'      == `"`W'/Demo2"'   // NB: $root is stamped absolute
assert `"$raw"'       == `"`W'/Demo2/01_raw"'
assert `"$converted"' == `"`W'/Demo2/01_raw/_converted"'
assert `"$cleaned"'   == `"`W'/Demo2/02_cleaned"'
assert `"$output"'    == `"`W'/Demo2/03_output"'
assert `"$code"'      == `"`W'/Demo2/_code"'
assert `"$docs"'      == `"`W'/Demo2/_documentation"'
foreach g in root raw converted cleaned output code docs {
    confirm file "${`g'}/."
}

di as text ""
di as text "{hline 70}"
di as text "projectbuilder v2.0.0: ALL TESTS PASSED"
di as text "{hline 70}"
