*! version 2.1.0  08aug2026  Eric A. Booth, Sr Researcher, Texas 2036
*!                           Elizabeth Teas, Sr Research Scientist, Far Harbor, LLC
*! projectbuilder -- scaffold a data-analysis project folder with a
*!                   numbered do-file pipeline, then (optionally) ingest
*!                   data, convert it, combine it, and build documentation.
*!
*! No organization-locked pieces: no shared-drive discovery, no template
*! folder, no logo fetcher.  Everything the scaffold needs is written by
*! this program with -file write-; nothing external is required.
*!
*! Cross-OS: uses only Stata's mkdir, copy, cd, and file commands;
*! no shell calls.  Companion to "Applied Program Evaluation Using Stata".
*! Support: eric.a.booth@gmail.com
*!
*! v2.1.0: the webdoc2 render is self-contained (a fallback header ships
*!         inside every project, so no net get / adopath step); new
*!         -sitebuild- subcommand writes a catalog page across projects;
*!         new -check- subcommand reports every optional companion in one
*!         table; the generated control file logs per-stage runtimes; raw
*!         files are checksummed so a rebuild reports new/changed/unchanged.

program define projectbuilder, rclass
    version 16

    * ---- subcommands: sitebuild, check -----------------------------------
    * Dispatched before -syntax- so they need no project name.  A project
    * literally named "sitebuild" or "check" cannot be scaffolded; both are
    * reserved words now, which the help file says out loud.
    gettoken pbfirst pbrest : 0, parse(" ,")
    if lower(`"`pbfirst'"') == "sitebuild" {
        pb_sitebuild `pbrest'
        return add
        exit
    }
    if lower(`"`pbfirst'"') == "check" {
        pb_check `pbrest'
        return add
        exit
    }

    syntax anything(name=projspec id="source[/subsource]") [, ///
        PATH(string)         ///
        DEScription(string)  ///
        URL(string)          ///
        DATA(string)         ///
        TOPIC(string)        ///
        PUBlicfacing(string) ///
        TIMEline(string)     ///
        OTHERnotes(string)   ///
        OUTcomes(string)     ///
        OVer(string)         ///
        DESCsave             ///
        REBUILD              ///
        REPLACE              ///
        BUILDDOCS            ///
        NOAUTOconvert]

    * ---- reject characters that cannot survive the trip to a file --------
    * Every free-text value here is eventually written into a do-file or a
    * documentation page, which means it is re-expanded on the way.  A
    * backtick does not survive that: it opens a macro reference that never
    * closes, and Stata stops with a bare "invalid syntax".  That used to
    * happen AFTER the folder tree was built, leaving a half-made project
    * that the corrected re-run then refused to touch (error 602).  Check it
    * first, before anything is created, and name the option at fault.
    foreach o in description url topic publicfacing timeline othernotes ///
                 outcomes over path data {
        if strpos(`"`macval(`o')'"', char(96)) {
            di as err `"projectbuilder: `o'() may not contain a backtick"'
            di as err  "                (it opens a macro reference Stata cannot close)."
            di as err  "                Use a plain apostrophe instead."
            exit 198
        }
    }
    if strpos(`"`macval(projspec)'"', char(96)) {
        di as err "projectbuilder: the project name may not contain a backtick"
        exit 198
    }

    * ---- park ~ so the file writer cannot mistake it for a marker --------
    * pb_wl writes $ and ` into the generated do-files by spelling them ~D
    * and ~B, then substituting.  It runs on the finished line, so it cannot
    * tell its own markers from a value that happens to contain "~D" -- and
    * "~D" is not far-fetched: url("https://example.edu/~Dave/data.csv") used
    * to be written out as ".../$ave/data.csv".  Hold every free-text value's
    * tildes on a control character until pb_wl has done its own pass, then
    * restore them (see pb_wl and pb_unesc below).
    *
    * A $ typed on the command line is a different matter and is NOT fixable
    * here: Stata expands globals while parsing the command, so the ado never
    * sees the $.  description("costs $M") reaches this program as
    * "costs " no matter what we do; write \$M to get a literal dollar sign.
    * The metadata read-back below IS under our control, and does preserve $.
    foreach o in description url topic timeline othernotes {
        local `o' = subinstr(`"`macval(`o')'"', char(126), char(5), .)
    }

    * Which code-affecting options did the user type on THIS call?  Recorded
    * before the metadata read-back below fills the same locals in from disk,
    * so the summary can tell "you asked for this" from "this was on record".
    local gave_code = 0
    if `"`outcomes'"' != "" | `"`over'"' != "" | "`descsave'" != "" local gave_code = 1

    * ---- validate publicfacing ------------------------------------------
    if !inlist(lower(strtrim(`"`publicfacing'"')), "", "yes", "no", "unsure") {
        di as err `"projectbuilder: publicfacing() must be yes, no, unsure, or empty (got "`publicfacing'")"'
        exit 198
    }
    local publicfacing = lower(strtrim(`"`publicfacing'"'))

    * ---- cap outcomes / over at 10 each ---------------------------------
    local outcomes_trim
    local n = 0
    foreach w of local outcomes {
        local ++n
        if `n' > 10 continue
        local outcomes_trim `outcomes_trim' `w'
    }
    if `n' > 10 di as txt "projectbuilder: outcomes() had `n' items; using first 10."
    local outcomes : copy local outcomes_trim

    local over_trim
    local n = 0
    foreach w of local over {
        local ++n
        if `n' > 10 continue
        local over_trim `over_trim' `w'
    }
    if `n' > 10 di as txt "projectbuilder: over() had `n' items; using first 10."
    local over : copy local over_trim

    * ---- base path: path() overrides the current working directory ------
    local base `"`c(pwd)'"'
    if `"`path'"' != "" local base `"`path'"'

    * A relative path() used to be carried through verbatim, so r(path) and
    * the -global root- stamped into 000_control.do came out relative -- both
    * documented as absolute, and the control file is the one thing that must
    * keep working after the project moves or someone else opens it.  Resolve
    * it against the current directory now.
    local isabs = 0
    if inlist(substr(`"`base'"', 1, 1), "/", "\")  local isabs = 1
    if regexm(`"`base'"', "^[a-zA-Z]:")            local isabs = 1
    if !`isabs' {
        local cwd `"`c(pwd)'"'
        if inlist(substr(`"`cwd'"', -1, 1), "/", "\") {
            local cwd = substr(`"`cwd'"', 1, strlen(`"`cwd'"') - 1)
        }
        if `"`base'"' == "." | `"`base'"' == "" local base `"`cwd'"'
        else                                    local base `"`cwd'/`base'"'
    }

    * Strip one trailing separator so the joins below never double it.  Doing
    * that blindly is what broke a bare root: path("/") left nothing at all,
    * and on Windows path("C:\") left the bare drive "C:".  Keep the
    * separator in those two cases and record that the joins must not add a
    * second one, rather than appending a slash and stamping "//Demo" into
    * the control file.
    local sep "/"
    if inlist(substr(`"`base'"', -1, 1), "/", "\") {
        local stripped = substr(`"`base'"', 1, strlen(`"`base'"') - 1)
        if `"`stripped'"' == "" {
            local base "/"                  // the filesystem root
            local sep  ""
        }
        else if regexm(`"`stripped'"', "^[a-zA-Z]:$") {
            local base `"`stripped'/"'      // a bare drive root, e.g. C:/
            local sep  ""
        }
        else local base `"`stripped'"'
    }
    else if regexm(`"`base'"', "^[a-zA-Z]:$") {
        local base `"`base'/"'              // "C:" alone means that drive's root
        local sep  ""
    }

    * ---- reject a stray extra token -------------------------------------
    * -anything- absorbs every word after the command name, so an unquoted
    * second word would silently become part of the folder name.  A project
    * name is exactly one token; quote it if it contains spaces.
    local pbrest `"`projspec'"'
    gettoken pbfirst pbrest : pbrest
    local pbrest = strtrim(`"`pbrest'"')
    if `"`pbrest'"' != "" {
        di as err `"projectbuilder: too many project names -- "`projspec'""'
        di as err  "                Give one name (source or source/subsource);"
        di as err `"                the extra token was "`pbrest'"."'
        di as err  "                Quote the name if it contains spaces."
        exit 198
    }

    * ---- parse source[/subsource] ---------------------------------------
    local projspec = subinstr(`"`projspec'"', char(34), "", .)
    local projspec = strtrim(`"`projspec'"')
    if `"`projspec'"' == "" {
        di as err "projectbuilder: project name is empty"
        exit 198
    }
    local pos = strpos(`"`projspec'"', "/")
    if `pos' > 0 {
        local parent = substr(`"`projspec'"', 1, `pos' - 1)
        local leaf   = substr(`"`projspec'"', `pos' + 1, .)
        local proj_label = subinstr(`"`projspec'"', "/", "_", .)
    }
    else {
        local parent ""
        local leaf   `"`projspec'"'
        local proj_label `"`leaf'"'
    }

    * ---- validate names (no path tricks) --------------------------------
    if strpos(`"`projspec'"', "..") | strpos(`"`projspec'"', "\") {
        di as err `"projectbuilder: "`projspec'" is not a valid project name (no ".." or "\" allowed)"'
        exit 198
    }
    if strpos(`"`leaf'"', "/") {
        di as err `"projectbuilder: at most one level of nesting -- use source or source/subsource"'
        exit 198
    }
    if `"`leaf'"' == "" | (`pos' > 0 & `"`parent'"' == "") {
        di as err "projectbuilder: source and subsource names cannot be empty"
        exit 198
    }

    if `"`parent'"' != "" local target `"`base'`sep'`parent'/`leaf'"'
    else                  local target `"`base'`sep'`leaf'"'

    * ---- rebuild vs. fresh scaffold; refuse to clobber ------------------
    * A fresh call never overwrites an existing project (exit 602).
    * -rebuild- opts in to working on an existing project; it preserves
    * any do-file in _code that the user edited unless -replace- is given.
    pb_isdir exists `"`target'"'
    if `exists' & "`rebuild'" == "" {
        di as err `"projectbuilder: target already exists -- `target'"'
        di as err  "                projectbuilder never overwrites an existing project."
        di as err  "                Rerun with -rebuild- to refresh it, or rename it and re-run."
        exit 602
    }
    * writecode=1 means (over)write the numbered do-files; on rebuild we
    * only write a code file that is missing, unless -replace- is given.
    local writecode = cond("`rebuild'" != "" & "`replace'" == "", 0, 1)

    if `exists' di as txt `"projectbuilder: rebuilding `target'"'
    else {
        di as txt `"projectbuilder: scaffolding `target'"'
        * -rebuild- on something that is not there is not an error: it just
        * scaffolds, which is what makes the command safe to put in a script
        * that runs on a schedule.  Say so, though.  A mistyped project name
        * with -rebuild- otherwise looks like a successful refresh, when what
        * actually happened is that a second, empty project appeared and the
        * real one was never touched.
        if "`rebuild'" != "" {
            di as txt  "                (-rebuild- was given but no project was there yet,"
            di as txt  "                 so this is a fresh scaffold. If you meant to refresh"
            di as txt  "                 an existing project, check the name and the path.)"
        }
    }

    * ---- build the folder tree (Stata's mkdir is cross-OS) --------------
    capture mkdir `"`base'"'
    pb_isdir baseok `"`base'"'
    if !`baseok' {
        capture confirm file `"`base'"'
        if !_rc {
            di as err `"projectbuilder: path() must name a directory -- `base' is a file"'
            exit 601
        }
        di as err `"projectbuilder: base path not found and could not be created -- `base'"'
        di as err  "                path() creates one level: its parent must already exist."
        exit 601
    }
    if `"`parent'"' != "" capture mkdir `"`base'`sep'`parent'"'
    capture mkdir `"`target'"'
    foreach sub in 01_raw 02_cleaned 03_output _code _documentation _archive {
        capture mkdir `"`target'/`sub'"'
    }
    capture mkdir `"`target'/01_raw/_archive"'
    capture mkdir `"`target'/01_raw/_converted"'
    capture mkdir `"`target'/02_cleaned/_archive"'
    capture mkdir `"`target'/03_output/_archive"'
    capture mkdir `"`target'/_code/_archive"'
    capture mkdir `"`target'/_documentation/_archive"'
    capture mkdir `"`target'/_documentation/website"'

    * Every mkdir above is captured, because re-running over an existing tree
    * must not be an error.  That also swallowed real failures: on a
    * read-only base the whole tree silently failed to appear and the run
    * carried on until the first -file open-, which stopped with a bare
    * r(603) naming a do-file, not the directory that could not be made.
    * Confirm the two folders everything else is written into.
    foreach sub in _code _documentation {
        pb_isdir subok `"`target'/`sub'"'
        if !`subok' {
            di as err `"projectbuilder: could not create `target'/`sub'"'
            di as err  "                The base path exists but is not writable, or the"
            di as err  "                project name is not legal on this filesystem."
            exit 693
        }
    }

    * ---- convenient path locals -----------------------------------------
    local raw       `"`target'/01_raw"'
    local converted `"`target'/01_raw/_converted"'
    local cleaned   `"`target'/02_cleaned"'
    local code      `"`target'/_code"'
    local docs      `"`target'/_documentation"'
    local web       `"`docs'/website"'

    * ---- metadata persistence -------------------------------------------
    * A plain -rebuild- must not discard what the scaffold recorded.  The
    * metadata is stored beside the documentation and read back whenever the
    * current call does not supply a value, so refreshing a project keeps its
    * description, topic, and the rest instead of replacing them with
    * placeholders.  An option given on this call always wins.
    local metaf `"`docs'/_project_meta.txt"'
    local nrawsig = 0
    capture confirm file `"`metaf'"'
    if _rc == 0 {
        tempname mfh
        capture file open `mfh' using `"`metaf'"', read text
        if _rc == 0 {
            file read `mfh' mline
            while r(eof) == 0 {
                if regexm(`"`macval(mline)'"', "^([a-z]+)=(.*)$") {
                    local mkey = regexs(1)
                    local mval = regexs(2)
                    * rawsig lines carry last run's raw-file checksums
                    * ("<checksum> <filename>"); collect them for the change
                    * report and skip the metadata parking below.
                    if "`mkey'" == "rawsig" {
                        local ++nrawsig
                        local rawsig`nrawsig' `"`macval(mval)'"'
                        file read `mfh' mline
                        continue
                    }
                    * A recorded value goes straight back into a local, so it
                    * must not be re-expanded on the way: -local x `"`mval'"'-
                    * ate a recorded $ (silently, then wrote the damaged text
                    * back out) and stopped dead on a recorded backtick, which
                    * left the project permanently un-rebuildable.  Copy the
                    * macro instead, and park the tildes exactly as the option
                    * values above were parked.  The help file says this file
                    * may be edited by hand, so it has to survive being edited.
                    if strpos(`"`macval(mval)'"', char(96)) {
                        di as txt `"projectbuilder: dropping `mkey'= from _project_meta.txt (it contains a backtick)"'
                    }
                    else {
                        local mval = subinstr(`"`macval(mval)'"', char(126), char(5), .)
                        * Park the $ as well.  Unlike a $ typed on the command
                        * line -- which Stata expands before this program is
                        * reached -- a recorded one arrives intact, and only
                        * gets eaten further downstream when the value is
                        * re-expanded on its way into pb_docs.  Hold it here
                        * and pb_wl/pb_docs will put it back at write time.
                        local mval = subinstr(`"`macval(mval)'"', char(36), char(1), .)
                        foreach m in description url topic publicfacing timeline ///
                                     othernotes outcomes over created descsave {
                            if "`mkey'" == "`m'" {
                                if `"``m''"' == "" local `m' : copy local mval
                            }
                        }
                    }
                }
                file read `mfh' mline
            }
            file close `mfh'
        }
    }

    * ---- values stamped into the scaffold files -------------------------
    local today : di %tdCCYY-NN-DD daily(`"`c(current_date)'"', "DMY")
    * -created- is the date the project was first scaffolded; -today- is when
    * this build ran.  They differ after a rebuild, so keep them separate.
    if `"`created'"' == "" local created `"`today'"'
    local lastbuilt `"`today'"'

    local author `"`c(username)'"'
    * The generated 000_control.do pins the language version to this package's
    * own floor rather than to the running Stata.  c(stata_version) can report
    * a release (19.5, say) that no earlier installation will accept, which
    * would make the generated file unrunnable for a teammate on Stata 16-19.
    * Raise the pin by hand if a project comes to rely on newer syntax.
    local sver "16.0"
    * Copy rather than re-expand: these values may hold a recorded $ that a
    * bare `"`description'"' would eat a second time.
    local descfull : copy local description
    if `"`descfull'"' == "" local descfull "(add a one-line description of the project here)"
    local url_show : copy local url
    if `"`url_show'"' == "" local url_show "(none recorded)"
    * url() may have come from the metadata file rather than this call, so
    * the live fetch below needs its tildes put back now.
    pb_unesc url_live `"`url'"'
    foreach m in topic publicfacing timeline othernotes {
        local `m'_show : copy local `m'
        if `"``m'_show'"' == "" local `m'_show "(not recorded)"
    }
    local gh "https://raw.githubusercontent.com/ericabooth"
    local urlbase ""
    * Take the basename from the PARKED url, not from url_live.  url_live has
    * already had its tildes restored, so a basename derived from it goes
    * through pb_wl on its way into 100_data_download.do -- and pb_wl reads
    * "~D" as its own marker.  A source at ".../~Dataset.csv" was written out
    * as "$raw/$ataset.csv", which at run time downloads into a hidden ".csv".
    * Keep it parked here; pb_unesc restores it for the live fetch below.
    if `"`url'"' != "" pb_base urlbase `"`url'"'

    * ---- record the metadata for the next rebuild ------------------------
    capture mkdir `"`docs'"'
    tempname mfw
    capture file open `mfw' using `"`metaf'"', write text replace
    if _rc == 0 {
        file write `mfw' "* projectbuilder metadata.  Read back on -rebuild- so a" _n
        file write `mfw' "* refresh keeps what the scaffold recorded.  Edit freely;" _n
        file write `mfw' "* one key=value per line." _n
        foreach m in description url topic publicfacing timeline othernotes ///
                     outcomes over created descsave {
            * Write the value the user typed, not the parked form: this file
            * is documented as hand-editable, so it must be readable text.
            pb_unesc mout `"``m''"'
            file write `mfw' "`m'=" `"`macval(mout)'"' _n
        }
        file close `mfw'
    }

    *=====================================================================*
    * WRITE THE NUMBERED PIPELINE (do-files in _code)                     *
    * Each file is guarded: on -rebuild- without -replace-, a file that   *
    * already exists (i.e., the user may have edited it) is left alone.   *
    *=====================================================================*
    tempname fh

    * ---- _code/000_control.do -------------------------------------------
    pb_guard dowrite `writecode' `"`code'/000_control.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/000_control.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 000_control.do -- `proj_label'"'
        pb_wl `fh' `"* Created `created' by `author' (scaffolded by projectbuilder v2.1.0)"'
        pb_wl `fh' `"* Last built `lastbuilt'"'
        pb_wl `fh' `"* `descfull'"'
        pb_wl `fh' `"* The control file: every path in one place."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `""'
        pb_wl `fh' `"clear all"'
        pb_wl `fh' `"version `sver'      // projectbuilder's floor; raise if you need newer syntax"'
        pb_wl `fh' `"set more off"'
        pb_wl `fh' `"set varabbrev off    // abbreviations hide bugs"'
        pb_wl `fh' `""'
        pb_wl `fh' `"*---------------------------------------------------------------"'
        pb_wl `fh' `"* >>> THE ONE PLACE YOU EDIT: the project root. <<<"'
        pb_wl `fh' `"* projectbuilder stamped the absolute path it scaffolded below."'
        pb_wl `fh' `"* If this project ever MOVES -- new machine, new teammate, new"'
        pb_wl `fh' `"* drive -- edit ONLY the global root line, then rerun this file."'
        pb_wl `fh' `"*---------------------------------------------------------------"'
        pb_wl `fh' `"global root "`target'""'
        pb_wl `fh' `""'
        pb_wl `fh' `"* Derived from root; you should not need to touch these."'
        pb_wl `fh' `"global raw       "~Droot/01_raw"            // untouched source files"'
        pb_wl `fh' `"global converted "~Droot/01_raw/_converted" // raw -> .dta, one per file"'
        pb_wl `fh' `"global cleaned   "~Droot/02_cleaned"        // the analytic file(s)"'
        pb_wl `fh' `"global output    "~Droot/03_output"         // logs, tables, exhibits"'
        pb_wl `fh' `"global code      "~Droot/_code"             // the do-files"'
        pb_wl `fh' `"global docs      "~Droot/_documentation"    // the documentation site"'
        pb_wl `fh' `"foreach d in raw converted cleaned output code docs {"'
        pb_wl `fh' `"    capture mkdir "~D{~Bd'}"     // safe to rerun"'
        pb_wl `fh' `"}"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* set scheme stcolor    // uncomment to pin one graphics style"'
        pb_wl `fh' `""'
        pb_wl `fh' `"*---------------------------------------------------------------"'
        pb_wl `fh' `"* Optional: run the whole numbered pipeline, in order."'
        pb_wl `fh' `"*---------------------------------------------------------------"'
        pb_wl `fh' `"local run_all 0    // flip to 1 to run every numbered step"'
        pb_wl `fh' `"if ~Brun_all' {"'
        pb_wl `fh' `"    * Each stage is timed, and the runtimes append to"'
        pb_wl `fh' `"    * _documentation/run_log.txt -- a free build history."'
        pb_wl `fh' `"    tempname rl"'
        pb_wl `fh' `"    capture confirm file "~Ddocs/run_log.txt""'
        pb_wl `fh' `"    if _rc file open ~Brl' using "~Ddocs/run_log.txt", write text replace"'
        pb_wl `fh' `"    else   file open ~Brl' using "~Ddocs/run_log.txt", write text append"'
        pb_wl `fh' `"    file write ~Brl' "---- pipeline run ~Bc(current_date)' ~Bc(current_time)' ----" _n"'
        pb_wl `fh' `"    foreach stg in 100_data_download 200_data_management 300_labels ///"'
        pb_wl `fh' `"                   400_data_profiler 500_aggregation 600_analysis {"'
        pb_wl `fh' `"        timer clear 99"'
        pb_wl `fh' `"        timer on 99"'
        pb_wl `fh' `"        * capture, so a failing stage is LOGGED and the log file is"'
        pb_wl `fh' `"        * closed before the failure is re-raised (still fails hard)."'
        pb_wl `fh' `"        capture noisily do "~Dcode/~Bstg'.do""'
        pb_wl `fh' `"        local stagerc = _rc"'
        pb_wl `fh' `"        timer off 99"'
        pb_wl `fh' `"        quietly timer list 99"'
        pb_wl `fh' `"        if ~Bstagerc' {"'
        pb_wl `fh' `"            file write ~Brl' "~Bstg'  FAILED r(~Bstagerc') after " %8.1f (r(t99)) " s" _n"'
        pb_wl `fh' `"            file close ~Brl'"'
        pb_wl `fh' `"            error ~Bstagerc'"'
        pb_wl `fh' `"        }"'
        pb_wl `fh' `"        file write ~Brl' "~Bstg'  " %8.1f (r(t99)) " s" _n"'
        pb_wl `fh' `"    }"'
        pb_wl `fh' `"    file close ~Brl'"'
        pb_wl `fh' `"}"'
        file close `fh'
    }

    * ---- _code/100_data_download.do -------------------------------------
    pb_guard dowrite `writecode' `"`code'/100_data_download.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/100_data_download.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 100_data_download.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: get the raw source files into ~Draw."'
        pb_wl `fh' `"* Raw files are write-once: downloaded/copied, never edited by hand."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        if `"`url'"' != "" {
            pb_wl `fh' `"* Source URL recorded from the url() option:"'
            pb_wl `fh' `"*   `url'"'
            pb_wl `fh' `"* Fetch it with Stata's -copy- (works for http/https URLs):"'
            pb_wl `fh' `"capture copy "`url'" "~Draw/`urlbase'", replace"'
            pb_wl `fh' `"if _rc di as txt "100: could not fetch the URL; check the address or drop the file into ~Draw by hand.""'
        }
        else {
            pb_wl `fh' `"* No source URL was recorded at scaffold time."'
            pb_wl `fh' `"* If the source lives at a URL, note it here and fetch with -copy-:"'
            pb_wl `fh' `"* copy "https://example.com/data.csv" "~Draw/data.csv", replace"'
            pb_wl `fh' `"* If the files arrive by hand (email, thumb drive, shared folder),"'
            pb_wl `fh' `"* drop them into ~Draw and record who sent them, and when, below."'
        }
        pb_wl `fh' `""'
        pb_wl `fh' `"* Provenance notes (who/where/when the raw files came from):"'
        pb_wl `fh' `"*   `othernotes_show'"'
        file close `fh'
    }

    * ---- _code/200_data_management.do -----------------------------------
    pb_guard dowrite `writecode' `"`code'/200_data_management.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/200_data_management.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 200_data_management.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: turn the raw drop in ~Draw into ONE analytic file"'
        pb_wl `fh' `"* in ~Dcleaned, in two passes:"'
        pb_wl `fh' `"*   Pass 1  convertanything : every csv/xlsx/dta in ~Draw -> .dta"'
        pb_wl `fh' `"*                             in ~Dconverted (names cleaned)."'
        pb_wl `fh' `"*   Pass 2  combineall      : append those .dta into the analytic file."'
        pb_wl `fh' `"* projectbuilder runs both passes for you at scaffold/rebuild time"'
        pb_wl `fh' `"* when the packages are installed; this file is the reproducible"'
        pb_wl `fh' `"* record of what it ran (and a teaching artifact if they are not)."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        pb_wl `fh' `"* --- Pass 1: convert every raw file to .dta -----------------------"'
        pb_wl `fh' `"capture which convertanything"'
        pb_wl `fh' `"if _rc {"'
        pb_wl `fh' `"    di as txt "convertanything not installed. Install it with:""'
        pb_wl `fh' `"    di as txt `"    net install convertanything, from("`gh'/convertanything-stata-public/main/") replace"'"'
        pb_wl `fh' `"}"'
        pb_wl `fh' `"else {"'
        pb_wl `fh' `"    convertanything using "~Draw", recursive ///"'
        pb_wl `fh' `"        saving("~Dconverted") replace clear cleannames compress"'
        pb_wl `fh' `"}"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* --- Pass 2: append the converted files into the analytic file ----"'
        pb_wl `fh' `"capture which combineall"'
        pb_wl `fh' `"if _rc {"'
        pb_wl `fh' `"    di as txt "combineall not installed. Install it with:""'
        pb_wl `fh' `"    di as txt `"    net install combineall, from("`gh'/combineall-stata-public/main/") replace"'"'
        pb_wl `fh' `"}"'
        pb_wl `fh' `"else {"'
        pb_wl `fh' `"    capture noisily combineall using "~Dcleaned/`proj_label'_analytic", ///"'
        pb_wl `fh' `"        cmethod(append) directory("~Dconverted") filetype(dta) replace"'
        pb_wl `fh' `"    if _rc di as txt "combineall found nothing to append; run Pass 1 first.""'
        pb_wl `fh' `"}"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* From here, load the analytic file and reshape/merge as the project needs:"'
        pb_wl `fh' `"* use "~Dcleaned/`proj_label'_analytic.dta", clear"'
        file close `fh'
    }

    * ---- _code/300_labels.do --------------------------------------------
    pb_guard dowrite `writecode' `"`code'/300_labels.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/300_labels.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 300_labels.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: variable/value labels and provenance on the analytic"'
        pb_wl `fh' `"* file, plus (optionally) a codebook export for the documentation."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        pb_wl `fh' `"use "~Dcleaned/`proj_label'_analytic.dta", clear"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* label variable somevar "Human-readable label""'
        pb_wl `fh' `"* label define yesno 0 "No" 1 "Yes""'
        pb_wl `fh' `"* label values flagvar yesno"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* --- Source lineage: tag each variable with the raw file it came"'
        pb_wl `fh' `"* from, then make that lineage searchable (author's -srctag-/-srcfind-)."'
        pb_wl `fh' `"capture which srctag"'
        pb_wl `fh' `"if _rc {"'
        pb_wl `fh' `"    di as txt "srctag/srcfind not installed (author's GitHub); skipping lineage tags.""'
        pb_wl `fh' `"}"'
        pb_wl `fh' `"else {"'
        pb_wl `fh' `"    * srctag takes a varlist, so name the variables (or _all).  It"'
        pb_wl `fh' `"    * writes char varname[source], which -datadictionary- harvests."'
        pb_wl `fh' `"    * srctag _all, source("~Draw")   // stamp every variable's origin"'
        pb_wl `fh' `"    * srcfind somevar               // later: search that lineage"'
        pb_wl `fh' `"}"'
        if "`descsave'" != "" {
            pb_wl `fh' `""'
            pb_wl `fh' `"* --- Codebook export via -descsave- (SSC: ssc install descsave) ----"'
            pb_wl `fh' `"capture which descsave"'
            pb_wl `fh' `"if _rc {"'
            pb_wl `fh' `"    di as txt "descsave not installed. Install it with:  ssc install descsave""'
            pb_wl `fh' `"}"'
            pb_wl `fh' `"else {"'
            pb_wl `fh' `"    * descsave writes a Stata dataset, one observation per variable."'
            pb_wl `fh' `"    * Its -using- names the file to DESCRIBE; the output file goes in"'
            pb_wl `fh' `"    * saving(), which is also where -replace- belongs.  Export the"'
            pb_wl `fh' `"    * result to .xlsx afterwards with Stata's own -export excel-, so"'
            pb_wl `fh' `"    * the codebook is readable by someone without Stata."'
            pb_wl `fh' `"    preserve"'
            pb_wl `fh' `"    descsave, list(name type format varlab vallab) ///"'
            pb_wl `fh' `"        saving("~Ddocs/`proj_label'_codebook.dta", replace)"'
            pb_wl `fh' `"    use "~Ddocs/`proj_label'_codebook.dta", clear"'
            pb_wl `fh' `"    capture noisily export excel using "~Ddocs/`proj_label'_codebook.xlsx", ///"'
            pb_wl `fh' `"        firstrow(variables) replace"'
            pb_wl `fh' `"    if _rc di as txt "codebook saved as .dta; the .xlsx export failed.""'
            pb_wl `fh' `"    restore"'
            pb_wl `fh' `"}"'
        }
        pb_wl `fh' `""'
        pb_wl `fh' `"compress"'
        pb_wl `fh' `"save "~Dcleaned/`proj_label'_analytic.dta", replace"'
        file close `fh'
    }

    * ---- _code/400_data_profiler.do -------------------------------------
    pb_guard dowrite `writecode' `"`code'/400_data_profiler.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/400_data_profiler.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 400_data_profiler.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: profile the analytic file -- distributions of the"'
        pb_wl `fh' `"* outcome variables, optionally broken down by the -over- variables."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        pb_wl `fh' `"use "~Dcleaned/`proj_label'_analytic.dta", clear"'
        pb_wl `fh' `""'
        pb_wl `fh' `"local outcomes "`outcomes'"   // recorded from outcomes(); edit freely"'
        pb_wl `fh' `"local over     "`over'"   // recorded from over(); edit freely"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* -table, statistic()- is the Stata 17 syntax.  000_control.do pins"'
        pb_wl `fh' `"* -version 16.0-, this package's floor, so this file has to work under"'
        pb_wl `fh' `"* that pin too: under 16 the statistic() option is a syntax error."'
        pb_wl `fh' `"* c(stata_version) is the RUNNING release, which is what decides."'
        pb_wl `fh' `"local newtable = (c(stata_version) >= 17)"'
        pb_wl `fh' `""'
        pb_wl `fh' `"foreach y of local outcomes {"'
        pb_wl `fh' `"    capture confirm variable ~By'"'
        pb_wl `fh' `"    if _rc continue          // silently skip vars not in this file"'
        pb_wl `fh' `"    summarize ~By', detail"'
        pb_wl `fh' `"    foreach g of local over {"'
        pb_wl `fh' `"        capture confirm variable ~Bg'"'
        pb_wl `fh' `"        if _rc continue"'
        pb_wl `fh' `"        if ~Bnewtable' {"'
        pb_wl `fh' `"            version 17: table ~Bg', statistic(mean ~By') statistic(count ~By')"'
        pb_wl `fh' `"        }"'
        pb_wl `fh' `"        else {"'
        pb_wl `fh' `"            tabstat ~By', by(~Bg') statistics(mean count)"'
        pb_wl `fh' `"        }"'
        pb_wl `fh' `"    }"'
        pb_wl `fh' `"}"'
        file close `fh'
    }

    * ---- _code/500_aggregation.do ---------------------------------------
    pb_guard dowrite `writecode' `"`code'/500_aggregation.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/500_aggregation.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 500_aggregation.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: build the aggregated/collapsed tables the analysis"'
        pb_wl `fh' `"* needs (e.g., one row per unit-period), written to ~Dcleaned."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        pb_wl `fh' `"use "~Dcleaned/`proj_label'_analytic.dta", clear"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* Typical shape of this step:"'
        pb_wl `fh' `"* collapse (mean) `outcomes', by(`over')"'
        pb_wl `fh' `"* save "~Dcleaned/`proj_label'_agg.dta", replace"'
        file close `fh'
    }

    * ---- _code/600_analysis.do ------------------------------------------
    pb_guard dowrite `writecode' `"`code'/600_analysis.do"'
    if `dowrite' {
        quietly file open `fh' using `"`code'/600_analysis.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* 600_analysis.do -- `proj_label'"'
        pb_wl `fh' `"* Single job: the analysis itself -- models, estimates, and the"'
        pb_wl `fh' `"* tables/figures for the deliverable, written to ~Doutput."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Globals come from 000_control.do -- run that first."'
        pb_wl `fh' `""'
        pb_wl `fh' `"use "~Dcleaned/`proj_label'_analytic.dta", clear"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* Suggested per-run log (dated, so runs never overwrite):"'
        pb_wl `fh' `"* log using "~Doutput/600_analysis_~DS_DATE.log", replace text"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* ... regress / logit / margins / graph / collect export ..."'
        pb_wl `fh' `"* graph export "~Doutput/fig01.png", replace width(2400)"'
        pb_wl `fh' `""'
        pb_wl `fh' `"* capture log close"'
        file close `fh'
    }

    *=====================================================================*
    * DOCUMENTATION SOURCES (index.do, _runall.do)                        *
    * Guarded like code: these are do-files the user may customize.       *
    *=====================================================================*

    * ---- _documentation/index.do ----------------------------------------
    pb_guard dowrite `writecode' `"`docs'/index.do"'
    if `dowrite' {
        quietly file open `fh' using `"`docs'/index.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* index.do -- documentation source for `proj_label'"'
        pb_wl `fh' `"* Rendered to website/index.html by _runall.do (needs webdoc2)."'
        pb_wl `fh' `"* If webdoc2 is absent, projectbuilder writes a plain index.html"'
        pb_wl `fh' `"* directly, so the documentation always exists."'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `""'
        pb_wl `fh' `"* Build it with:  webdoc2 "index.do"   (see _runall.do)"'
        pb_wl `fh' `"* Content subcommands: wdinit, wputh1, wput (edit freely)."'
        pb_wl `fh' `""'
        pb_wl `fh' `"* wdinit injects a header file it locates with -findfile-.  If"'
        pb_wl `fh' `"* webdoc2's own header.html is installed (adopath or this folder),"'
        pb_wl `fh' `"* it wins; otherwise _runall.do stages header_fallback.html --"'
        pb_wl `fh' `"* which projectbuilder writes into this folder on every run --"'
        pb_wl `fh' `"* under the name wdinit looks for.  Either way the render has a"'
        pb_wl `fh' `"* header, with no extra install step."'
        pb_wl `fh' `"wdinit index, replace"'
        pb_wl `fh' `"wputh1 `proj_label'"'
        pb_wl `fh' `"wput `descfull'"'
        pb_wl `fh' `"wput <b>Source URL:</b> `url_show'"'
        pb_wl `fh' `"wput <b>Topic:</b> `topic_show'"'
        pb_wl `fh' `"wput <b>Public-facing:</b> `publicfacing_show'"'
        pb_wl `fh' `"wput <b>Refresh timeline:</b> `timeline_show'"'
        pb_wl `fh' `"wput <b>Other notes:</b> `othernotes_show'"'
        file close `fh'
    }

    * ---- _documentation/_runall.do --------------------------------------
    pb_guard dowrite `writecode' `"`docs'/_runall.do"'
    if `dowrite' {
        quietly file open `fh' using `"`docs'/_runall.do"', write text replace
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* _runall.do -- build website/index.html for `proj_label'"'
        pb_wl `fh' `"*==============================================================="'
        pb_wl `fh' `"* Prettier docs use webdoc2 (author's GitHub; needs -ssc install webdoc-)."'
        pb_wl `fh' `"* projectbuilder always writes website/index.html directly as a"'
        pb_wl `fh' `"* fallback; this renders the webdoc2 version when it is available."'
        pb_wl `fh' `"* The header the render injects is settled inside index.do: webdoc2's"'
        pb_wl `fh' `"* own header.html when installed, else the header_fallback.html that"'
        pb_wl `fh' `"* projectbuilder writes into this folder on every run.  Nothing needs"'
        pb_wl `fh' `"* to be fetched or moved onto the adopath."'
        pb_wl `fh' `"capture which webdoc2"'
        pb_wl `fh' `"if _rc {"'
        pb_wl `fh' `"    di as txt "webdoc2 not installed; using the built-in website/index.html.""'
        pb_wl `fh' `"    di as txt "  ssc install webdoc""'
        pb_wl `fh' `"    di as txt `"  net install webdoc2, from("`gh'/webdoc2-stata-public/main/") replace"'"'
        pb_wl `fh' `"}"'
        pb_wl `fh' `"else {"'
        pb_wl `fh' `"    * cd so webdoc2 finds index.do.  The path is stamped literally"'
        pb_wl `fh' `"    * rather than taken from ~Ddocs: projectbuilder runs this file"'
        pb_wl `fh' `"    * itself under -builddocs-, and at that point 000_control.do has"'
        pb_wl `fh' `"    * not run, so ~Ddocs is undefined."'
        pb_wl `fh' `"    local here "`docs'""'
        pb_wl `fh' `"    cd "~Bhere'""'
        pb_wl `fh' `"    * No header.html anywhere?  Stage the fallback projectbuilder"'
        pb_wl `fh' `"    * wrote into this folder under the name wdinit's -findfile-"'
        pb_wl `fh' `"    * looks for, and remove it again after the render.  Staging by"'
        pb_wl `fh' `"    * copy (rather than wdinit's headerfile() option) works on every"'
        pb_wl `fh' `"    * webdoc2 version in the field."'
        pb_wl `fh' `"    local staged 0"'
        pb_wl `fh' `"    capture findfile "header.html""'
        pb_wl `fh' `"    if _rc {"'
        pb_wl `fh' `"        capture copy "header_fallback.html" "header.html""'
        pb_wl `fh' `"        if !_rc local staged 1"'
        pb_wl `fh' `"    }"'
        pb_wl `fh' `"    capture noisily webdoc2 "index.do""'
        pb_wl `fh' `"    local wrc = _rc"'
        pb_wl `fh' `"    if ~Bstaged' capture erase "header.html""'
        pb_wl `fh' `"    if ~Bwrc' {"'
        pb_wl `fh' `"        di as txt "webdoc2 render skipped; the built-in website/index.html remains.""'
        pb_wl `fh' `"    }"'
        pb_wl `fh' `"    else {"'
        pb_wl `fh' `"        * webdoc2 writes index.html BESIDE index.do, but the project's"'
        pb_wl `fh' `"        * documentation page is website/index.html -- that is what the"'
        pb_wl `fh' `"        * run points you at, and what the built-in fallback writes."'
        pb_wl `fh' `"        * Put the rendered page where everything says it is."'
        pb_wl `fh' `"        capture copy "~Bhere'/index.html" "~Bhere'/website/index.html", replace"'
        pb_wl `fh' `"        if _rc {"'
        pb_wl `fh' `"            di as txt "webdoc2 rendered index.html, but it could not be copied""'
        pb_wl `fh' `"            di as txt "into website/; the built-in page remains.""'
        pb_wl `fh' `"            local wrc = 603"'
        pb_wl `fh' `"        }"'
        pb_wl `fh' `"    }"'
        pb_wl `fh' `"    * Hand the outcome back: projectbuilder decides what to report from"'
        pb_wl `fh' `"    * this file's return code, so swallowing it here made every render"'
        pb_wl `fh' `"    * look successful."'
        pb_wl `fh' `"    exit ~Bwrc'"'
        pb_wl `fh' `"}"'
        file close `fh'
    }

    *=====================================================================*
    * METHOD A: INGEST DATA NOW  (data() and/or url())                    *
    *=====================================================================*
    if `"`data'"' != "" {
        local dsrc `"`data'"'
        if inlist(substr(`"`dsrc'"', -1, 1), "/", "\") {
            local dsrc = substr(`"`dsrc'"', 1, strlen(`"`dsrc'"') - 1)
        }
        pb_isdir dsrcdir `"`dsrc'"'
        if `dsrcdir' {
            * a directory: copy every (non-hidden) file into 01_raw/
            capture local dfiles : dir `"`dsrc'"' files "*"
            if _rc {
                di as err `"projectbuilder: data("`data'") is a directory that cannot be listed."'
                exit 601
            }
            local ncopy = 0
            local nskip = 0
            foreach f of local dfiles {
                if substr(`"`macval(f)'"', 1, 1) == "." continue
                capture copy `"`dsrc'/`macval(f)'"' `"`raw'/`macval(f)'"', replace
                if !_rc local ++ncopy
                else {
                    local ++nskip
                    di as txt `"projectbuilder: could not copy `macval(f)'"'
                }
            }
            di as txt `"projectbuilder: copied `ncopy' file(s) from `dsrc' into 01_raw/"'
            * A skipped file used to be invisible: the count went down and the
            * run still said OK, so a locked or unreadable source file dropped
            * out of the analytic file without anyone being told.
            if `nskip' > 0 ///
                di as err `"projectbuilder: `nskip' file(s) in data() could NOT be copied (see above)."'
        }
        else {
            capture confirm file `"`dsrc'"'
            if !_rc {
                pb_base bn `"`dsrc'"'
                copy `"`dsrc'"' `"`raw'/`bn'"', replace
                di as txt `"projectbuilder: copied 1 file into 01_raw/ (`bn')"'
            }
            else {
                * You asked for data and got none.  This used to be one -as txt-
                * note among several, and the run still ended "projectbuilder
                * OK", so the first thing a reader of Workflow A saw was an
                * empty project reported as a success.
                di as err `"projectbuilder: data("`data'") does not exist; NOTHING was copied into 01_raw/."'
                di as err  "                The scaffold was still built. Check the path -- a"
                di as err  "                relative one is read from the current directory --"
                di as err `"                then rerun with -rebuild-."'
            }
        }
    }
    if `"`url_live'"' != "" {
        * urlbase is parked (see above); the file on disk needs the real name.
        pb_unesc ubn `"`urlbase'"'
        capture copy `"`url_live'"' `"`raw'/`macval(ubn)'"', replace
        if !_rc di as txt `"projectbuilder: fetched `url_live' into 01_raw/ (`macval(ubn)')"'
        else    di as txt `"projectbuilder: url() not reachable now; the fetch is written into 100_data_download.do to run later."'
    }

    * ---- count raw files -------------------------------------------------
    pb_count nraw `"`raw'"' "*"

    * ---- raw-file change report ------------------------------------------
    * Every run records each raw file's checksum as a rawsig= line in
    * _project_meta.txt; a rebuild compares against last run's record and
    * says which files are new, changed, and unchanged -- a lightweight
    * cousin of -project-'s (SSC) dependency tracking.
    capture local rawlist : dir `"`raw'"' files "*"
    if _rc local rawlist ""
    local nnew  = 0
    local nchg  = 0
    local nsame = 0
    local chgnames ""
    local nsigout = 0
    foreach f of local rawlist {
        if substr(`"`macval(f)'"', 1, 1) == "." continue
        capture quietly checksum `"`raw'/`macval(f)'"'
        if _rc continue
        local crc `"`r(checksum)'"'
        local ++nsigout
        local sigout`nsigout' `"`crc' `macval(f)'"'
        local status "new"
        forvalues j = 1/`nrawsig' {
            gettoken scrc sfn : rawsig`j'
            local sfn = strtrim(`"`macval(sfn)'"')
            if `"`macval(sfn)'"' == `"`macval(f)'"' {
                local status = cond(`"`scrc'"' == `"`crc'"', "same", "changed")
                continue, break
            }
        }
        if "`status'" == "new"     local ++nnew
        if "`status'" == "same"    local ++nsame
        if "`status'" == "changed" {
            local ++nchg
            local chgnames `"`chgnames' `macval(f)'"'
        }
    }
    if `exists' & `nrawsig' > 0 {
        di as txt "projectbuilder: raw files vs last run: `nnew' new, `nchg' changed, `nsame' unchanged"
        if `nchg' > 0 di as txt `"                changed:`chgnames'"'
    }
    if `nsigout' > 0 {
        tempname mfs
        capture file open `mfs' using `"`metaf'"', write text append
        if _rc == 0 {
            forvalues j = 1/`nsigout' {
                file write `mfs' "rawsig=" `"`macval(sigout`j')'"' _n
            }
            file close `mfs'
        }
    }

    *=====================================================================*
    * AUTO-PASS: convertanything -> combineall over 01_raw/               *
    * (projectbuilder's own run; the do-file holds the reproducible copy) *
    *=====================================================================*
    * The auto-pass runs -convertanything, clear- and -combineall-, and both
    * load data.  Without the -preserve- below, scaffolding a project threw
    * away whatever the user had in memory: -sysuse auto- followed by
    * -projectbuilder MyProj, rebuild- came back with the converted file
    * loaded and the auto data gone, silently, with no warning.  A command
    * that builds folders has no business touching the user's data, so put it
    * back.  -preserve- is a no-op when nothing is in memory.
    local pbrestore = 0
    if `nraw' > 0 & "`noautoconvert'" == "" {
        capture which convertanything
        local haveconv = (_rc == 0)
        capture which combineall
        local havecomb = (_rc == 0)
        if `haveconv' | `havecomb' {
            preserve
            local pbrestore = 1
        }
        if !`haveconv' {
            di as txt "projectbuilder: convertanything not installed; skipping auto-convert."
            di as txt `"                install: net install convertanything, from("`gh'/convertanything-stata-public/main/") replace"'
        }
        else {
            di as txt "projectbuilder: converting 01_raw/ -> 01_raw/_converted/ ..."
            capture noisily convertanything using `"`raw'"', recursive ///
                saving(`"`converted'"') replace clear cleannames compress
        }
        * combine only if there is something converted to combine
        pb_count nconverted `"`converted'"' "*.dta"
        if `nconverted' > 0 {
            if !`havecomb' {
                di as txt "projectbuilder: combineall not installed; skipping auto-combine."
                di as txt `"                install: net install combineall, from("`gh'/combineall-stata-public/main/") replace"'
            }
            else {
                di as txt "projectbuilder: appending converted files -> 02_cleaned/`proj_label'_analytic.dta ..."
                capture noisily combineall using "`cleaned'/`proj_label'_analytic", ///
                    cmethod(append) directory("`converted'") filetype(dta) replace
            }
        }
        else {
            * Do not tell the user to install a package they already have, and
            * do not repeat the install line already printed two lines above.
            di as txt "projectbuilder: nothing converted yet; skipping auto-combine."
            if `haveconv' ///
                di as txt "                (nothing in 01_raw/ could be converted; check the file types.)"
            else ///
                di as txt "                (that is expected without convertanything -- see above.)"
        }
        if `pbrestore' restore
        * Converted fewer files than went in?  Say so.  Two raw files sharing
        * a stem -- survey.csv and survey.dta -- both convert to survey.dta
        * and the second overwrites the first, which is otherwise visible only
        * as a count that does not add up.
        if `haveconv' & `nconverted' > `nraw' {
            di as txt "projectbuilder: `nconverted' converted file(s) but only `nraw' raw file(s)."
            di as txt "                01_raw/_converted/ still holds output from raw files that"
            di as txt "                are no longer there, and it is all being appended into the"
            di as txt "                analytic file. Delete the stale .dta files to drop them."
        }
        if `haveconv' & `nconverted' > 0 & `nconverted' < `nraw' {
            di as txt "projectbuilder: `nraw' raw file(s) produced `nconverted' converted file(s)."
            di as txt "                Files that share a name but not an extension convert to"
            di as txt "                the same .dta and overwrite each other; others may simply"
            di as txt "                not be convertible. Check 01_raw/_converted/."
        }
    }
    else if `nraw' == 0 {
        di as txt "projectbuilder: 01_raw/ is empty -- scaffold only (Workflow B:"
        di as txt "                put files in 01_raw/, then rerun with -rebuild-)."
    }

    * ---- count converted files ------------------------------------------
    pb_count nconverted `"`converted'"' "*.dta"

    *=====================================================================*
    * DOCUMENTATION OUTPUT: always build website/index.html + Readme.md   *
    * webdoc2 (via builddocs) only makes it prettier.                     *
    *=====================================================================*
    local built_stamp `"`today' `c(current_time)'"'

    * The fallback header is a derived artifact, rewritten every run, so the
    * webdoc2 render always has a header to inject with no install step.
    pb_fallbackheader `"`docs'/header_fallback.html"' `"`proj_label'"'

    pb_docs `"`web'/index.html"' `"`docs'/Readme.md"' `"`raw'"' `"`converted'"' `"`cleaned'"' ///
        , project(`"`proj_label'"') date(`"`created'"') author(`"`author'"') ///
          desc(`"`descfull'"') url(`"`url_show'"') topic(`"`topic_show'"') ///
          public(`"`publicfacing_show'"') timeline(`"`timeline_show'"') ///
          othernotes(`"`othernotes_show'"') stamp(`"`built_stamp'"')

    if "`builddocs'" != "" {
        capture which webdoc2
        if _rc {
            di as txt "projectbuilder: webdoc2 not installed; used the built-in HTML fallback."
            di as txt "                install: ssc install webdoc"
            di as txt `"                         net install webdoc2, from("`gh'/webdoc2-stata-public/main/") replace"'
        }
        else {
            di as txt "projectbuilder: rendering documentation with webdoc2 ..."
            * Quietly: _runall.do echoes its own source otherwise, and a
            * webdoc2 failure ends in a bare r(601) that reads as a crash
            * even though it is caught and the built-in HTML is kept.
            * _runall.do cd's into _documentation; save and restore the cwd.
            * If the cwd has been deleted out from under the session, c(pwd)
            * comes back empty and a bare -cd ""- silently lands the user in
            * their home directory.  Only restore what we actually captured.
            local pb_pwd `"`c(pwd)'"'
            capture quietly do `"`docs'/_runall.do"'
            local renderrc = _rc
            if `"`pb_pwd'"' != "" quietly cd `"`pb_pwd'"'
            if `renderrc' {
                di as txt "                webdoc2 render did not finish (r(`renderrc')); the built-in"
                di as txt "                website/index.html is unchanged and still complete."
                di as txt `"                To see why, run: do "`docs'/_runall.do""'
            }
            else di as txt "                rendered."
        }
    }

    *=====================================================================*
    * SUMMARY + NEXT STEPS                                                *
    *=====================================================================*
    * Show the values the user typed, not the parked form.
    foreach m in descfull url_show topic_show timeline_show othernotes_show {
        pb_unesc `m' `"``m''"'
    }
    di as txt _n "{hline 66}"
    di as txt "projectbuilder OK  (v2.1.0)"
    di as txt `"  Project       : `proj_label'"'
    di as txt `"  Location      : `target'"'
    di as txt `"  Description   : `macval(descfull)'"'
    di as txt `"  Source URL    : `macval(url_show)'"'
    di as txt `"  Raw files     : `nraw'"'
    di as txt `"  Converted     : `nconverted'"'
    di as txt `"  Outcomes      : `outcomes'"'
    di as txt `"  Over          : `over'"'
    di as txt `"  Descsave      : `=cond("`descsave'" != "", "yes", "no")'"'
    di as txt `"  Topic         : `macval(topic_show)'"'
    di as txt `"  Public-facing : `publicfacing_show'"'
    di as txt `"  Timeline      : `macval(timeline_show)'"'
    di as txt `"  Other notes   : `macval(othernotes_show)'"'
    di as txt `"  Mode          : `=cond(`exists', "rebuild", "fresh scaffold")'"'
    * outcomes(), over() and descsave are shown above because they were
    * recorded -- but on a bare rebuild the do-file that would carry them is
    * one of the guarded ones, so _code/ still holds the old values.  Say so
    * rather than letting the banner imply the change landed.
    if `exists' & !`writecode' & `gave_code' {
        di as txt "  NOTE: outcomes()/over()/descsave were recorded, but _code/ was"
        di as txt "        left as you edited it. Add -replace- to rewrite it."
    }
    * The other direction: -replace- overwrote them in place, with no copy
    * kept anywhere.  The _archive/ folders look like they might catch this;
    * they do not, and nothing else does either.
    if `exists' & `writecode' {
        di as txt "  NOTE: -replace- rewrote the do-files in _code/ from the shipped"
        di as txt "        templates. Any edits you had made to them are gone."
    }
    di as txt "{hline 66}"
    * The name is printed back inside a runnable command.  It was printed
    * bare, so a project named "Vendor Feed 2027" produced a "Rerun:" line that
    * projectbuilder itself rejects with "too many project names".  Quote it
    * when it contains a space.
    local projshow : copy local projspec
    if strpos(`"`projspec'"', " ") local projshow `""`projspec'""'
    * ... and it dropped path() too, so the hint only worked from the one
    * directory the user happened to be standing in.  Carry it.
    * NB: options are separated by spaces, not commas -- only the first comma
    * belongs, the one that opens the option list.
    local pathshow `"path("`base'") "'
    local rerun `"`projshow', `pathshow'rebuild"'
    di as txt _n "Next steps:"
    if `nraw' == 0 {
        di as txt  "  1. Put the raw source files in 01_raw/ (or edit"
        di as txt  "     _code/100_data_download.do to fetch them by URL)."
        di as txt `"  2. Rerun:  projectbuilder `rerun'"'
        di as txt  "     -- this converts, combines, and rebuilds the docs."
        di as txt `"  3. do "`code'/000_control.do"   then work down 100..600."'
    }
    else {
        * There are raw files, but that does not mean the analytic file got
        * built: on an install without convertanything/combineall -- the
        * default state -- nothing is converted and nothing is combined.  The
        * next steps used to say "Review 02_cleaned/<project>_analytic.dta"
        * regardless, sending a first-time user to a file that was never
        * created.  Say what is actually on disk.
        capture confirm file `"`cleaned'/`proj_label'_analytic.dta"'
        local haveanalytic = (_rc == 0)
        di as txt `"  1. do "`code'/000_control.do"    (sets the path globals)"'
        if `haveanalytic' {
            di as txt  "  2. Review 02_cleaned/`proj_label'_analytic.dta, then work down"
            di as txt  "     the pipeline: 300_labels -> 400_data_profiler ->"
            di as txt  "     500_aggregation -> 600_analysis."
            di as txt  "  3. Every data refresh is just another:"
            di as txt `"       projectbuilder `rerun'"'
        }
        else {
            di as txt  "  2. There is no 02_cleaned/`proj_label'_analytic.dta yet, so the"
            di as txt  "     pipeline from 300_labels on has nothing to read. Either:"
            if "`noautoconvert'" != "" {
                di as txt  "       - drop -noautoconvert- and rerun with"
                di as txt `"         -projectbuilder `rerun'-, or"'
            }
            else {
                di as txt  "       - install the optional companions named above and rerun"
                di as txt `"         with -projectbuilder `rerun'-, or"'
            }
            di as txt  "       - build the analytic file yourself and save it there"
            di as txt `"         (see _code/200_data_management.do)."'
            di as txt  "  3. Then work down 300_labels -> 400_data_profiler ->"
            di as txt  "     500_aggregation -> 600_analysis."
        }
    }
    di as txt `"  Docs: `web'/index.html"'

    * ---- stored results --------------------------------------------------
    return local project     `"`proj_label'"'
    return local path        `"`target'"'
    return scalar nraw       = `nraw'
    return scalar nconverted = `nconverted'
    return scalar rebuilt    = cond(`exists', 1, 0)
end


*=====================================================================*
* HELPERS                                                             *
*=====================================================================*

* --- pb_isdir: set the caller's local `retname' to 1 if `p' is an existing
*     DIRECTORY, else 0.  Mata's direxists() answers exactly that question on
*     every platform, with no side effects.
*
*     This replaces -capture confirm file "<dir>/."-, which was used in three
*     places and whose behavior on Windows the authors could not confirm.
*     The alternative of -capture cd- into the directory was rejected: it
*     moves the working directory to ask a question, and it reports "missing"
*     for a directory that merely cannot be entered.
program define pb_isdir
    gettoken retname 0 : 0
    gettoken p 0 : 0
    local r = 0
    mata: st_local("r", strofreal(direxists(st_local("p"))))
    c_local `retname' `r'
end

* --- pb_unesc: restore the characters parked by the caller -- char(5) back
*     to ~, char(1) back to $ -- for text that is about to be shown or
*     written outside pb_wl.
program define pb_unesc
    gettoken retname 0 : 0
    gettoken s 0 : 0
    local s = subinstr(`"`macval(s)'"', char(5), char(126), .)
    local s = subinstr(`"`macval(s)'"', char(1), char(36),  .)
    c_local `retname' `"`macval(s)'"'
end

* --- pb_wl: write one line, turning ~D into a literal $ and ~B into a
*     literal backtick.  The line is written as a string EXPRESSION, so the
*     substituted characters are never re-parsed by the macro processor --
*     which lets a self-contained ado emit files full of $globals and
*     `locals' without any template folder or -filefilter-.
*
*     The two ~ markers run FIRST, then char(5) is turned back into a real ~.
*     That order is what makes the markers unambiguous: the caller has
*     already parked every user-supplied tilde on char(5), so by the time
*     this runs, the only "~D" left in the line is one this program wrote.
*     Before that, url("https://example.edu/~Dave/data.csv") came out of here
*     as ".../$ave/data.csv".
program define pb_wl
    gettoken fh 0 : 0
    file write `fh' (subinstr(subinstr(subinstr(subinstr(`0',    ///
        "~D", char(36), .), "~B", char(96), .),                  ///
        char(5), char(126), .), char(1), char(36), .)) _n
end

* --- pb_guard: set the caller's local `flag' to 1 if the code file should
*     be (over)written -- i.e., writecode==1, or the file does not yet exist.
program define pb_guard
    gettoken flag 0 : 0
    gettoken wc   0 : 0
    gettoken f    0 : 0
    local go = `wc'
    capture confirm file `"`f'"'
    if _rc local go = 1
    c_local `flag' `go'
end

* --- pb_base: set the caller's local `retname' to the basename (last path
*     segment) of a path/URL.  Strips any trailing ? query.  Falls back to
*     download.dat.
program define pb_base
    gettoken retname 0 : 0
    gettoken p 0 : 0
    local q = strpos(`"`p'"', "?")
    if `q' > 0 local p = substr(`"`p'"', 1, `q' - 1)
    local s = max(strrpos(`"`p'"', "/"), strrpos(`"`p'"', "\"))
    if `s' > 0 local p = substr(`"`p'"', `s' + 1, .)
    if `"`p'"' == "" local p "download.dat"
    c_local `retname' `"`p'"'
end

* --- pb_count: set the caller's local `retname' to the count of non-hidden
*     files matching a pattern in a directory.
program define pb_count
    gettoken retname 0 : 0
    gettoken dir 0 : 0
    gettoken pat 0 : 0
    * -: dir- stops with r(601) when the path is missing or is not a
    * directory, which used to abort the whole run from inside a counter.
    * A folder we cannot list simply holds no files we can see.
    capture local list : dir `"`dir'"' files `"`pat'"'
    if _rc {
        c_local `retname' 0
        exit
    }
    local k = 0
    foreach f of local list {
        if substr(`"`f'"', 1, 1) == "." continue
        local ++k
    }
    c_local `retname' `k'
end

* --- pb_docs: write the fallback website/index.html and _documentation/
*     Readme.md, stamped with metadata and a listing of what is in 01_raw/,
*     01_raw/_converted/, and 02_cleaned/.  Always run, so docs always exist.
program define pb_docs
    gettoken html   0 : 0
    gettoken readme 0 : 0
    gettoken rawd   0 : 0
    gettoken convd  0 : 0
    gettoken cleand 0 : 0
    syntax [, project(string) date(string) author(string) desc(string) ///
        url(string) topic(string) public(string) timeline(string) ///
        othernotes(string) stamp(string) ]

    * ---- escape the recorded metadata -----------------------------------
    * The metadata is free text, so topic("a&b <tag>") has to appear as
    * itself rather than as markup.  The two outputs need different escaping,
    * and the Markdown copy used to be derived from the HTML one -- so
    * "R&D" was written into Readme.md as "R&amp;D".  That renders correctly
    * on a site that parses entities, but Readme.md is a file people also read
    * raw, in an editor or a terminal, where it is just wrong.
    *
    * HTML: &, <, and > all become entities.
    * Markdown: only what Markdown itself would misread -- | would open an
    * extra table column, and < would open a raw HTML tag.  A bare & is
    * ordinary text in Markdown and is left alone.
    foreach m in project date author desc url topic public timeline ///
                 othernotes stamp {
        * Put back the ~ (and any $) the caller parked, before escaping.
        local `m' = subinstr(`"`macval(`m')'"', char(5), char(126), .)
        local `m' = subinstr(`"`macval(`m')'"', char(1), char(36),  .)
        * Markdown first, from the unescaped value.
        local md_`m' = subinstr(`"`macval(`m')'"', "|", "\|",  .)
        local md_`m' = subinstr(`"`macval(md_`m')'"', "<", "&lt;", .)
        * then HTML.
        local `m' = subinstr(`"`macval(`m')'"', "&", "&amp;", .)
        local `m' = subinstr(`"`macval(`m')'"', "<", "&lt;",  .)
        local `m' = subinstr(`"`macval(`m')'"', ">", "&gt;",  .)
    }

    tempname fh

    * ---- website/index.html ---------------------------------------------
    quietly file open `fh' using `"`html'"', write text replace
    file write `fh' "<!doctype html>" _n
    file write `fh' `"<html lang="en"><head><meta charset="utf-8">"' _n
    file write `fh' `"<meta name="viewport" content="width=device-width, initial-scale=1">"' _n
    file write `fh' `"<title>`macval(project)' -- project documentation</title>"' _n
    file write `fh' "<style>" _n
    file write `fh' "body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;" _n
    file write `fh' "max-width:820px;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#1a1a1a}" _n
    file write `fh' "h1{margin-bottom:.2rem} table{border-collapse:collapse;margin:1rem 0}" _n
    file write `fh' "th,td{text-align:left;padding:.3rem .8rem;border-bottom:1px solid #ddd;vertical-align:top}" _n
    file write `fh' "code{background:#f4f4f4;padding:.1rem .3rem;border-radius:3px}" _n
    file write `fh' ".muted{color:#666;font-size:.9rem}</style></head><body>" _n
    file write `fh' `"<h1>`macval(project)'</h1>"' _n
    file write `fh' `"<p>`macval(desc)'</p>"' _n
    file write `fh' "<table>" _n
    file write `fh' `"<tr><th>Created</th><td>`macval(date)'</td></tr>"' _n
    file write `fh' `"<tr><th>Author</th><td>`macval(author)'</td></tr>"' _n
    file write `fh' `"<tr><th>Source URL</th><td>`macval(url)'</td></tr>"' _n
    file write `fh' `"<tr><th>Topic</th><td>`macval(topic)'</td></tr>"' _n
    file write `fh' `"<tr><th>Public-facing</th><td>`macval(public)'</td></tr>"' _n
    file write `fh' `"<tr><th>Refresh timeline</th><td>`macval(timeline)'</td></tr>"' _n
    file write `fh' `"<tr><th>Other notes</th><td>`macval(othernotes)'</td></tr>"' _n
    file write `fh' "</table>" _n
    pb_htmllist `fh' `"`rawd'"'   "*"      "Raw files (01_raw/)"
    pb_htmllist `fh' `"`convd'"'  "*.dta"  "Converted files (01_raw/_converted/)"
    pb_htmllist `fh' `"`cleand'"' "*.dta"  "Analytic files (02_cleaned/)"
    file write `fh' `"<p class="muted">Built `macval(stamp)' by projectbuilder v2.1.0."' _n
    file write `fh' " Install webdoc2 for a richer rendering.</p>" _n
    file write `fh' "</body></html>" _n
    file close `fh'

    * ---- _documentation/Readme.md ---------------------------------------
    quietly file open `fh' using `"`readme'"', write text replace
    file write `fh' `"# `macval(md_project)'"' _n _n
    file write `fh' `"`macval(md_desc)'"' _n _n
    file write `fh' "| Field | Value |" _n
    file write `fh' "|-------|-------|" _n
    file write `fh' `"| Created | `macval(md_date)' |"' _n
    file write `fh' `"| Author | `macval(md_author)' |"' _n
    file write `fh' `"| Source URL | `macval(md_url)' |"' _n
    file write `fh' `"| Topic | `macval(md_topic)' |"' _n
    file write `fh' `"| Public-facing | `macval(md_public)' |"' _n
    file write `fh' `"| Refresh timeline | `macval(md_timeline)' |"' _n
    file write `fh' `"| Other notes | `macval(md_othernotes)' |"' _n
    file write `fh' _n
    pb_mdlist `fh' `"`rawd'"'   "*"     "Raw files (01_raw/)"
    pb_mdlist `fh' `"`convd'"'  "*.dta" "Converted files (01_raw/_converted/)"
    pb_mdlist `fh' `"`cleand'"' "*.dta" "Analytic files (02_cleaned/)"
    file write `fh' _n `"_Built `macval(md_stamp)' by projectbuilder v2.1.0._"' _n
    file close `fh'
end

program define pb_htmllist
    gettoken fh  0 : 0
    gettoken dir 0 : 0
    gettoken pat 0 : 0
    gettoken hdr 0 : 0
    file write `fh' `"<h3>`hdr'</h3>"' _n
    * As in pb_count: a folder we cannot list simply shows no files, rather
    * than stopping the run with r(601) from inside the documentation writer.
    capture local list : dir `"`dir'"' files `"`pat'"'
    if _rc local list ""
    local any = 0
    file write `fh' "<ul>" _n
    foreach f of local list {
        if substr(`"`f'"', 1, 1) == "." continue
        local fe = subinstr(`"`f'"',  "&", "&amp;", .)
        local fe = subinstr(`"`fe'"', "<", "&lt;",  .)
        local fe = subinstr(`"`fe'"', ">", "&gt;",  .)
        file write `fh' `"<li><code>`fe'</code></li>"' _n
        local any = 1
    }
    if !`any' file write `fh' `"<li class="muted">(none yet)</li>"' _n
    file write `fh' "</ul>" _n
end

program define pb_mdlist
    gettoken fh  0 : 0
    gettoken dir 0 : 0
    gettoken pat 0 : 0
    gettoken hdr 0 : 0
    file write `fh' `"## `hdr'"' _n _n
    capture local list : dir `"`dir'"' files `"`pat'"'
    if _rc local list ""
    local any = 0
    foreach f of local list {
        if substr(`"`macval(f)'"', 1, 1) == "." continue
        * Markdown escaping only -- see the note in pb_docs.  A file called
        * "R&D notes.csv" is listed as itself, not as "R&amp;D notes.csv".
        local fe = subinstr(`"`macval(f)'"',  "|", "\|",   .)
        local fe = subinstr(`"`macval(fe)'"', "<", "&lt;", .)
        file write `fh' `"- `macval(fe)'"' _n
        local any = 1
    }
    if !`any' file write `fh' "- (none yet)" _n
    file write `fh' _n
end


* --- pb_fallbackheader: write the self-contained header the webdoc2 render
*     falls back on.  Injected into <head> by wdinit when webdoc2's own
*     header.html is not installed.  No CDN links: the page must be readable
*     offline and inside an agency network that blocks external fetches.
program define pb_fallbackheader
    version 16
    gettoken hf 0 : 0
    gettoken proj 0 : 0
    tempname fh
    quietly file open `fh' using `"`hf'"', write text replace
    file write `fh' "<!-- header_fallback.html -- written by projectbuilder v2.1.0." _n
    file write `fh' "     Used by index.do's wdinit only when webdoc2's own header.html" _n
    file write `fh' "     is not installed.  Rewritten on every projectbuilder run; put" _n
    file write `fh' "     customizations in a header.html instead (it wins). -->" _n
    file write `fh' `"<meta charset="utf-8">"' _n
    file write `fh' `"<meta name="viewport" content="width=device-width, initial-scale=1">"' _n
    file write `fh' "<style>" _n
    file write `fh' "body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;" _n
    file write `fh' "max-width:860px;margin:2rem auto;padding:0 1rem;line-height:1.55;color:#1a1a2e}" _n
    file write `fh' "h1{margin-bottom:.3rem;color:#1b2d55} h2{color:#1b2d55;border-bottom:2px solid #d44500;" _n
    file write `fh' "padding-bottom:.2rem} h3{color:#1b2d55}" _n
    file write `fh' "a{color:#2b6cb0} table{border-collapse:collapse;margin:1rem 0}" _n
    file write `fh' "th,td{text-align:left;padding:.3rem .8rem;border-bottom:1px solid #dee2e6;vertical-align:top}" _n
    file write `fh' "pre{background:#f5f7fa;border:1px solid #dee2e6;border-radius:4px;padding:.8rem;" _n
    file write `fh' "overflow-x:auto;font-size:.9rem;line-height:1.4}" _n
    file write `fh' "code{background:#f5f7fa;padding:.1rem .3rem;border-radius:3px;font-size:.9em}" _n
    file write `fh' ".stinp{color:#1b2d55;font-weight:600} .stoup{color:#1a1a2e}" _n
    file write `fh' ".muted{color:#6c7a8d;font-size:.9rem}" _n
    file write `fh' "</style>" _n
    file close `fh'
end

* --- pb_sitebuild: the cross-project catalog.  Scans a base directory for
*     project folders (anything holding _documentation/_project_meta.txt),
*     reads each project's recorded metadata, and writes projects_index.html
*     and projects_index.md at the base -- one page that links every
*     project's documentation site.  This is the piece that makes a folder
*     of projectbuilder projects into a browsable portfolio.
program define pb_sitebuild, rclass
    version 16
    syntax [, PATH(string) TITLE(string)]

    foreach o in path title {
        if strpos(`"`macval(`o')'"', char(96)) {
            di as err "projectbuilder sitebuild: `o'() may not contain a backtick"
            exit 198
        }
    }

    local base `"`c(pwd)'"'
    if `"`path'"' != "" local base `"`path'"'
    local isabs = 0
    if inlist(substr(`"`base'"', 1, 1), "/", "\") local isabs = 1
    if regexm(`"`base'"', "^[a-zA-Z]:")           local isabs = 1
    if !`isabs' local base `"`c(pwd)'/`base'"'
    if inlist(substr(`"`base'"', -1, 1), "/", "\") ///
        local base = substr(`"`base'"', 1, strlen(`"`base'"') - 1)
    pb_isdir okdir `"`base'"'
    if !`okdir' {
        di as err `"projectbuilder sitebuild: `base' is not a directory"'
        exit 601
    }
    if `"`title'"' == "" local title "Project catalog"

    capture local dirs : dir `"`base'"' dirs "*"
    if _rc local dirs ""

    local stamp `"`c(current_date)' `c(current_time)'"'
    tempname hh mm
    quietly file open `hh' using `"`base'/projects_index.html"', write text replace
    quietly file open `mm' using `"`base'/projects_index.md"',   write text replace

    * html head (same look as the per-project fallback pages)
    file write `hh' "<!doctype html>" _n
    file write `hh' `"<html lang="en"><head><meta charset="utf-8">"' _n
    file write `hh' `"<meta name="viewport" content="width=device-width, initial-scale=1">"' _n
    local etitle = subinstr(`"`title'"', "&", "&amp;", .)
    local etitle = subinstr(`"`etitle'"', "<", "&lt;", .)
    file write `hh' `"<title>`etitle'</title>"' _n
    file write `hh' "<style>" _n
    file write `hh' "body{font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;" _n
    file write `hh' "max-width:1000px;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#1a1a2e}" _n
    file write `hh' "h1{margin-bottom:.2rem;color:#1b2d55} table{border-collapse:collapse;margin:1rem 0;width:100%}" _n
    file write `hh' "th,td{text-align:left;padding:.35rem .8rem;border-bottom:1px solid #dee2e6;vertical-align:top}" _n
    file write `hh' "th{border-bottom:2px solid #1b2d55} a{color:#2b6cb0}" _n
    file write `hh' ".muted{color:#6c7a8d;font-size:.9rem}</style></head><body>" _n
    file write `hh' `"<h1>`etitle'</h1>"' _n
    file write `hh' "<table>" _n
    file write `hh' "<tr><th>Project</th><th>Description</th><th>Topic</th><th>Created</th><th>Public-facing</th><th>Docs</th></tr>" _n

    file write `mm' `"# `title'"' _n _n
    file write `mm' "| Project | Description | Topic | Created | Public-facing | Docs |" _n
    file write `mm' "|---------|-------------|-------|---------|---------------|------|" _n

    local np = 0
    foreach d of local dirs {
        if substr(`"`macval(d)'"', 1, 1) == "." continue
        if inlist(`"`macval(d)'"', "_archive", "_code", "_documentation") continue
        local mf `"`base'/`macval(d)'/_documentation/_project_meta.txt"'
        capture confirm file `"`mf'"'
        if _rc continue
        local ++np
        * read this project's recorded metadata
        foreach k in description topic created publicfacing {
            local p_`k' ""
        }
        tempname pf
        capture file open `pf' using `"`mf'"', read text
        if _rc == 0 {
            file read `pf' pline
            while r(eof) == 0 {
                if regexm(`"`macval(pline)'"', "^([a-z]+)=(.*)$") {
                    local pkey = regexs(1)
                    local pval = regexs(2)
                    if !strpos(`"`macval(pval)'"', char(96)) {
                        foreach k in description topic created publicfacing {
                            if "`pkey'" == "`k'" & `"`p_`k''"' == "" ///
                                local p_`k' : copy local pval
                        }
                    }
                }
                file read `pf' pline
            }
            file close `pf'
        }
        * the docs link, only if the page is actually there
        local dlink ""
        capture confirm file `"`base'/`macval(d)'/_documentation/website/index.html"'
        if !_rc local dlink `"`macval(d)'/_documentation/website/index.html"'
        * escape for each output
        foreach k in description topic created publicfacing {
            local h_`k' = subinstr(`"`macval(p_`k')'"', "&", "&amp;", .)
            local h_`k' = subinstr(`"`macval(h_`k')'"', "<", "&lt;",  .)
            local h_`k' = subinstr(`"`macval(h_`k')'"', ">", "&gt;",  .)
            local m_`k' = subinstr(`"`macval(p_`k')'"', "|", "\|",    .)
            local m_`k' = subinstr(`"`macval(m_`k')'"', "<", "&lt;",  .)
        }
        local hd = subinstr(`"`macval(d)'"', "&", "&amp;", .)
        local hd = subinstr(`"`hd'"', "<", "&lt;", .)
        file write `hh' `"<tr><td><b>`hd'</b></td><td>`macval(h_description)'</td><td>`macval(h_topic)'</td><td>`macval(h_created)'</td><td>`macval(h_publicfacing)'</td>"' _n
        if `"`dlink'"' != "" file write `hh' `"<td><a href="`dlink'">site</a></td></tr>"' _n
        else                 file write `hh' `"<td class="muted">(not built)</td></tr>"' _n
        local md = subinstr(`"`macval(d)'"', "|", "\|", .)
        if `"`dlink'"' != "" local mlink `"[site](`dlink')"'
        else                 local mlink "(not built)"
        file write `mm' `"| `macval(md)' | `macval(m_description)' | `macval(m_topic)' | `macval(m_created)' | `macval(m_publicfacing)' | `mlink' |"' _n
    }
    if `np' == 0 {
        file write `hh' `"<tr><td colspan="6" class="muted">(no projectbuilder projects found under this folder)</td></tr>"' _n
        file write `mm' "| (none found) | | | | | |" _n
    }
    file write `hh' "</table>" _n
    file write `hh' `"<p class="muted">Built `stamp' by projectbuilder v2.1.0 sitebuild. Rerun after any project changes.</p>"' _n
    file write `hh' "</body></html>" _n
    file close `hh'
    file write `mm' _n `"_Built `stamp' by projectbuilder v2.1.0 sitebuild._"' _n
    file close `mm'

    di as txt "projectbuilder sitebuild: " as res `np' as txt " project(s) cataloged"
    di as txt `"  Catalog: `base'/projects_index.html (+ projects_index.md)"'
    return scalar nprojects = `np'
    return local catalog `"`base'/projects_index.html"'
end

* --- pb_check: one table for every optional companion -- installed or not,
*     what it adds, and the exact install command, clickable.  This replaces
*     five install hints scattered across five different moments.
program define pb_check, rclass
    version 16
    syntax [, *]
    if `"`options'"' != "" {
        di as err "projectbuilder check: takes no options"
        exit 198
    }
    local gh "https://raw.githubusercontent.com/ericabooth"

    di as txt "{hline 74}"
    di as txt "projectbuilder check -- optional companions (none are required)"
    di as txt "{hline 74}"
    local missing ""
    local nmiss = 0

    * name : what it adds : install line(s), | separated
    local c1 `"convertanything|bulk-converts 01_raw/ to .dta|net install convertanything, from("`gh'/convertanything-stata-public/main/") replace"'
    local c2 `"combineall|appends converted files into the analytic file|net install combineall, from("`gh'/combineall-stata-public/main/") replace"'
    local c3 `"descsave|codebook export from 300_labels.do|ssc install descsave"'
    local c4 `"srctag|per-variable source lineage (with srcfind)|net install srctag, from("`gh'/srctag-stata-public/main/") replace"'
    local c5 `"srcfind|searches the lineage srctag writes|net install srctag, from("`gh'/srctag-stata-public/main/") replace"'
    local c6 `"datadictionary|codebook workbook; harvests srctag's tags|ssc install datadictionary"'
    local c7 `"webdoc2|prettier documentation render|net install webdoc2, from("`gh'/webdoc2-stata-public/main/") replace"'

    forvalues j = 1/7 {
        gettoken cname crest : c`j', parse("|")
        gettoken bar   crest : crest, parse("|")
        gettoken cwhat crest : crest, parse("|")
        gettoken bar   crest : crest, parse("|")
        local cinst `"`crest'"'
        capture which `cname'
        if _rc == 0 {
            di as txt "  " %-16s "`cname'" as res "installed  " as txt "`cwhat'"
        }
        else {
            di as txt "  " %-16s "`cname'" as err "missing    " as txt "`cwhat'"
            di as txt _col(30) `"{stata `"`cinst'"':`cinst'}"'
            if "`cname'" == "webdoc2" ///
                di as txt _col(30) `"{stata "ssc install webdoc":ssc install webdoc}  (webdoc2 builds on it)"'
            local ++nmiss
            local missing "`missing' `cname'"
        }
    }
    di as txt "{hline 74}"
    if `nmiss' == 0 di as txt "  All companions are installed."
    else di as txt "  Each install line above is clickable. projectbuilder works without them."
    local missing : list retokenize missing
    return local  missing  "`missing'"
    return scalar nmissing = `nmiss'
end
