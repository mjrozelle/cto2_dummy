*! cto2_dummy.ado - Generate dummy datasets from SurveyCTO/ODK instrument definitions
*! Author: Michael Rozelle <michael.rozelle@wur.nl>
*! Version 0.0.1  Created: March 2026

// Helper: parse a single SurveyCTO condition and apply it
cap program drop _cto2_dummy_apply_rel
program define _cto2_dummy_apply_rel
	args vname qtype raw_condition

	if "`raw_condition'" == "" | "`raw_condition'" == "." exit

	local rel "`raw_condition'"

	// Replace #{var} references with variable names
	local rel = ustrregexra("`rel'", "#\{(\w+)\}", "$1")
	// Replace single = with ==
	local rel = ustrregexra("`rel'", "([^!<>=])=([^=])", "$1==$2")
	local rel = ustrregexra("`rel'", "^=([^=])", "==$1")
	// Replace 'and'/'or' with '&'/'|'
	local rel = subinstr("`rel'", " and ", " & ", .)
	local rel = subinstr("`rel'", " or ", " | ", .)
	// Replace selected() patterns
	local rel = ustrregexra("`rel'", "selected\((\w+),[ ]*'([^']+)'\)", "$1==$2")
	local rel = ustrregexra("`rel'", "selected\((\w+),[ ]*""([^""]+)""\)", "$1==$2")
	// Replace not() with !()
	local rel = subinstr("`rel'", "not(", "!(", .)

	// Apply: set to missing where condition is false
	if `qtype' == 1 | `qtype' == 3 {
		cap replace `vname' = "" if !(`rel')
	}
	else if inlist(`qtype', 2, 4, 5, 6, 7) {
		cap replace `vname' = . if !(`rel')
	}

end

cap program drop cto2_dummy
program define cto2_dummy, rclass

syntax, ///
	INSTname(string) /// filepath to the Excel survey instrument
	SAVEfolder(string) /// filepath to the folder where dummy datasets should be saved
	[DK(integer -777) /// value used to indicate "don't know" responses
	OTHER(integer -555) /// value used to indicate "other (specify)" responses
	REFUSED(integer -999) /// value used to indicate "refused to answer" responses
	REPLACE /// overwrite existing .dta files
	NOBS(integer 1000) /// number of observations in main dataset
	MAXreps(integer 10)] // maximum repetitions per repeat group

version 16

qui {

preserve
local original_frame `c(frame)'

*===============================================================================
* 	Validate inputs
*===============================================================================

cap confirm file "`instname'"
if _rc {
	display as error "instrument file not found: `instname'"
	exit 601
}

cap confirm file "`savefolder'/nul"
if _rc {
	cap mkdir "`savefolder'"
}

set seed 12345

*===============================================================================
* 	Phase 2: Parse Survey Sheet
*===============================================================================

noisily display as text "Parsing survey instrument..."

tempname qs
frame create `qs'
cwf `qs'

import excel "`instname'", firstrow clear sheet(survey)

// Drop empty rows
ds, has(type string)
local strvars `r(varlist)'
if "`strvars'" != "" {
	local dropcond
	local first = 1
	foreach v of local strvars {
		if `first' {
			local dropcond missing(`v')
			local first = 0
		}
		else {
			local dropcond `dropcond' & missing(`v')
		}
	}
	drop if `dropcond'
}

// Ensure key columns exist and are string
foreach v in type name calculation relevant repeat_count constraint {
	cap confirm variable `v'
	if _rc {
		gen str1 `v' = ""
	}
	cap tostring `v', replace force
	replace `v' = "" if `v' == "."
}

// Handle labels
cap confirm variable label
if !_rc {
	rename label labelEnglishen
	clonevar labelStata = labelEnglishen
}
else {
	cap confirm variable labelEnglishen
	if _rc gen str1 labelEnglishen = ""
	cap confirm variable labelStata
	if _rc clonevar labelStata = labelEnglishen
}
cap tostring labelStata, replace force
cap tostring labelEnglishen, replace force
replace labelStata = "" if labelStata == "."
replace labelEnglishen = "" if labelEnglishen == "."
replace labelStata = labelEnglishen if missing(labelStata) | labelStata == ""

// Clean up dollar signs (prevent Stata macro expansion)
foreach v of varlist labelEnglishen labelStata repeat_count relevant calculation constraint {
	cap replace `v' = subinstr(`v', "$", "#", .)
	cap replace `v' = subinstr(`v', char(10), " ", .)
	cap replace `v' = subinstr(`v', `"""', "", .)
}

replace name = subinstr(name, ".", "", .)
replace name = strtrim(stritrim(name))

replace type = strtrim(stritrim(type))
replace type = subinstr(type, " ", "_", .) ///
	if inlist(type, "begin group", "end group", "begin repeat", "end repeat")

// Split type into type (question type) and type2 (list name)
split type
// type1 = question type keyword, type2 = list_name for selects
cap confirm variable type2
if _rc gen str1 type2 = ""
replace type2 = "" if type2 == "."

*------------------------------------------------------------------
*	Classify Question Types
*------------------------------------------------------------------

gen preloaded = regexm(calculation, "^pulldata")
gen note = type == "note"

// Detect numeric calculate fields
local numeric_formulae index area number round count count-if sum ///
	sum-if min min-if max max-if distance-between int abs duration
local regex
local g = 0
local length_mac = wordcount("`numeric_formulae'")
foreach n in `numeric_formulae' {
	local ++g
	if `g' == `length_mac' local regex `regex'`n'
	else local regex `regex'`n'|
}
local regex_pattern "^(?:`regex')\("
gen numeric_calculate = ustrregexm(calculation, "`regex_pattern'")

// Also detect if() wrapping numeric results as numeric
replace numeric_calculate = 1 if regexm(calculation, "^if\(") & ///
	!regexm(calculation, "pulldata")

label define question_type_M 1 "String" 2 "Select One" 3 "Select Multiple" ///
	4 "Numeric" 5 "Date" 6 "Datetime" 7 "GPS" ///
	-111 "Group Boundary" -222 "Note" -555 "Other"

gen question_type = .
label values question_type question_type_M

replace question_type = 1 if inlist(type1, "text", "deviceid", "image", ///
	"geotrace", "photo", "audit", "barcode", "simserial", "phonenumber") ///
	| preloaded == 1 ///
	| (type1 == "calculate" & numeric_calculate == 0)

replace question_type = 2 if type1 == "select_one" & missing(question_type)
replace question_type = 3 if type1 == "select_multiple"
replace question_type = 4 if !inlist(type1, "date", "text") & missing(question_type)
replace question_type = 5 if inlist(type1, "date", "today")
replace question_type = 6 if inlist(type1, "start", "end", "submissiondate")
replace question_type = 7 if type1 == "geopoint"

replace question_type = -111 if inlist(type1, "begin_group", "end_group", ///
	"begin_repeat", "end_repeat")
replace question_type = -222 if note == 1
replace question_type = -555 if missing(question_type)

// Drop unclassifiable types but keep group boundaries
drop if question_type == -555

gen order = _n

*===============================================================================
* 	Phase 3: Parse Choices Sheet
*===============================================================================

noisily display as text "Parsing choices..."

tempname choices
frame create `choices'

frame `choices' {

	import excel "`instname'", firstrow clear sheet(choices)

	cap rename listname list_name
	cap rename list_name list_name

	foreach v in list_name name label {
		cap confirm variable `v'
		if _rc {
			display as error "choices sheet is missing column: `v'"
			exit 198
		}
	}

	keep list_name name label

	// Drop empty rows
	drop if missing(list_name) & missing(name) & missing(label)

	tostring name, replace force
	replace name = strtrim(name)

	// Keep only numeric choice values
	drop if !regexm(name, "^[\-]?[0-9]+$")

	gen order = _n
	gen real_value = real(name)

	// Map special codes to extended missing
	gen str3 name1 = name
	if `dk' != 1 replace name1 = ".d" if name == "`dk'"
	if `refused' != 1 replace name1 = ".r" if name == "`refused'"
	if `other' != 1 replace name1 = ".o" if name == "`other'"

	// Clean labels
	replace label = subinstr(label, "$", "#", .)
	replace label = subinstr(label, `"""', "", .)
	replace label = subinstr(label, char(10), "", .)
	replace list_name = subinstr(list_name, " ", "", .)

	compress

}

*===============================================================================
* 	Phase 4: Parse Settings Sheet
*===============================================================================

tempname settings
frame create `settings'

frame `settings' {
	cap import excel "`instname'", firstrow clear sheet(settings)
	if _rc {
		local form_id "dummy_survey"
		local form_version "1"
	}
	else {
		cap confirm variable form_id
		if !_rc {
			local form_id = form_id[1]
		}
		else local form_id "dummy_survey"

		cap confirm variable version
		if !_rc {
			local form_version = version[1]
		}
		else local form_version "1"
	}
}

frame drop `settings'

noisily display as text "Form: `form_id' (version `form_version')"

*===============================================================================
* 	Phase 5: Build Group & Repeat Group Hierarchy
*===============================================================================

noisily display as text "Building group hierarchy..."

cwf `qs'

tempname groups
frame create `groups' int gtype strL gname strL glabel strL repeat_count ///
	int repetitions int instrument_row int gindex strL conditions int within ///
	int layers_nested

local n_groups = 0
local n_repeats = 0
local grouplist 0
local r_grouplist 0

gen group = 0
gen repeat_group = 0

sort order
forvalues i = 1/`c(N)' {

	if type1[`i'] == "begin_group" {

		local ++n_groups
		local grouplist = strtrim(stritrim("`grouplist' `n_groups'"))

		frame post `groups' (1) ("`=name[`i']'") ("`=labelStata[`i']'") ///
			("`=repeat_count[`i']'") (.) (`i') (`n_groups') ///
			("`=relevant[`i']'") (`=real(word("`grouplist'", -2))') (0)

	}

	else if type1[`i'] == "begin_repeat" {

		local ++n_repeats
		local r_grouplist = strtrim(stritrim("`r_grouplist' `n_repeats'"))

		frame post `groups' (2) ("`=name[`i']'") ("`=labelStata[`i']'") ///
			("`=repeat_count[`i']'") (.) (`i') (`n_repeats') ///
			("`=relevant[`i']'") (`=real(word("`r_grouplist'", -2))') (0)

	}

	else if type1[`i'] == "end_group" {

		local grouplist = strtrim(stritrim("`grouplist'"))
		local grouplist = ///
			substr("`grouplist'", 1, length("`grouplist'") ///
			- strlen(word("`grouplist'", -1)))

	}

	else if type1[`i'] == "end_repeat" {

		local r_grouplist = strtrim(stritrim("`r_grouplist'"))
		local r_grouplist = ///
			substr("`r_grouplist'", 1, length("`r_grouplist'") ///
			- length(word("`r_grouplist'", -1)))

	}

	local current_group = word("`grouplist'", -1)
	local current_repeat = word("`r_grouplist'", -1)

	replace group = `current_group' in `i'
	replace repeat_group = `current_repeat' in `i'

}

// Build cumulative relevancy for repeat groups
tempname repeat_groups
frame copy `groups' `repeat_groups'
frame `repeat_groups' {

	drop if gtype == 1

	if `c(N)' > 0 {
		gen cumulative_con = conditions
		local rgrs = `c(N)'

		forvalues i = `rgrs'(-1)1 {

			local w = within[`i']
			while `w' != 0 {

				replace cumulative_con = cumulative_con[`w'] + ///
					cond(!missing(cumulative_con) & cumulative_con != "", ///
					" & " + cumulative_con, "") ///
					if _n == `i'
				local w = within[`w']

			}

		}
	}
	else {
		gen str1 cumulative_con = ""
	}

}

// Build cumulative relevancy for standard groups
tempname nonrepeat_groups
frame copy `groups' `nonrepeat_groups'
frame `nonrepeat_groups' {

	drop if gtype == 2

	if `c(N)' > 0 {
		gen cumulative_con = conditions
		local grs = `c(N)'

		forvalues i = `grs'(-1)1 {

			local w = within[`i']
			while `w' != 0 {

				replace cumulative_con = cumulative_con[`w'] + ///
					cond(!missing(cumulative_con) & cumulative_con != "", ///
					" & " + cumulative_con, "") ///
					if _n == `i'
				local w = within[`w']

			}

		}
	}
	else {
		gen str1 cumulative_con = ""
	}

}

// Keep group conditions accessible for per-condition relevancy application
// (don't merge into a single cumulative expression - apply each separately)
cwf `qs'

*===============================================================================
* 	Build value label definitions
*===============================================================================

noisily display as text "Building value labels..."

// Get all distinct choice lists
frame `choices' {
	levelsof list_name, local(all_lists) clean
}

// Store label definition commands indexed by list_name
foreach listo in `all_lists' {

	local lab_cmd_`listo' `"label define `listo'"'

	frame `choices' {
		levelsof order if list_name == "`listo'", clean local(choice_rows)
	}

	foreach row in `choice_rows' {
		frame `choices' {
			local val = name1[`row']
			local lab = label[`row']
			// Truncate label to 80 chars for Stata compatibility
			local lab = substr(`"`lab'"', 1, 80)
		}
		local lab_cmd_`listo' `"`lab_cmd_`listo'' `val' "`lab'""'
	}

}


*===============================================================================
* 	Phase 6: Generate Dummy Data
*===============================================================================

noisily display as text "Generating main dataset (`nobs' observations)..."

// Drop notes and group boundaries from the working survey frame
cwf `qs'
drop if question_type == -222
sort order

*----------------------------------------------------------------------
* 6a. Create main dataset
*----------------------------------------------------------------------

tempname maindata
frame create `maindata'
frame `maindata' {

	set obs `nobs'

	// KEY - unique identifier
	gen str50 KEY = "uuid:" + string(_n, "%015.0f") + ///
		"-" + string(floor(runiform() * 100000), "%05.0f")

	// SubmissionDate
	gen double SubmissionDate = clock("2025-01-01 08:00:00", "YMDhms") + ///
		floor(runiform() * 365 * 24 * 3600) * 1000
	format SubmissionDate %tc
	label variable SubmissionDate "Submission Date"

	// formdef_version
	gen str20 formdef_version = "`form_version'"
	label variable formdef_version "Form Definition Version"

	// starttime
	gen double starttime = SubmissionDate - floor(runiform() * 3600 + 600) * 1000
	format starttime %tc
	label variable starttime "Start Time"

	// endtime
	gen double endtime = SubmissionDate
	format endtime %tc
	label variable endtime "End Time"

	// deviceid
	gen str40 deviceid = "device_" + string(floor(runiform() * 999999), "%06.0f")
	label variable deviceid "Device ID"

	// Define all value labels in this frame
	foreach listo in `all_lists' {
		cap `lab_cmd_`listo''
	}

}

*----------------------------------------------------------------------
* 6b. Generate variables by type (survey-level only)
*----------------------------------------------------------------------

// Process survey-level variables (repeat_group == 0)
cwf `qs'
local N_qs = _N

forvalues i = 1/`N_qs' {

	// Skip group boundaries
	if question_type[`i'] == -111 continue

	// Skip variables inside repeat groups
	if repeat_group[`i'] != 0 continue

	local vname = name[`i']
	local qtype = question_type[`i']
	local vtype = type1[`i']
	local vlabel = substr(labelStata[`i'], 1, 80)
	local vallabel = type2[`i']
	local vconstraint = constraint[`i']
	local vcalculation = calculation[`i']

	// Skip if variable name is empty
	if "`vname'" == "" | "`vname'" == "." continue

	frame `maindata' {

		// Check if variable already exists (e.g., metadata)
		cap confirm variable `vname'
		if !_rc continue

		// === String (type 1) ===
		if `qtype' == 1 {

			if inlist("`vtype'", "deviceid", "simserial") {
				gen str30 `vname' = "dev_" + string(floor(runiform() * 999999), "%06.0f")
			}
			else if "`vtype'" == "phonenumber" {
				gen str15 `vname' = "+232" + string(floor(runiform() * 99999999), "%08.0f")
			}
			else if "`vtype'" == "barcode" {
				gen str20 `vname' = "BC" + string(floor(runiform() * 9999999999), "%010.0f")
			}
			else if "`vtype'" == "calculate" {
				// Try to evaluate the calculation
				local calc "`vcalculation'"
				// Replace #{var} with var
				local calc = ustrregexra("`calc'", "#\{(\w+)\}", "$1")
				// Replace if() with cond()
				local calc = subinstr("`calc'", "if(", "cond(", .)
				// Replace single = with == (but not != or <=  or >=)
				local calc = ustrregexra("`calc'", "([^!<>=])=([^=])", "$1==$2")
				cap gen str80 `vname' = `calc'
				if _rc {
					gen str30 `vname' = "calc_" + string(_n)
				}
			}
			else {
				// Generic text
				gen str30 `vname' = "text_" + string(_n, "%04.0f") + ///
					"_" + string(floor(runiform() * 9999), "%04.0f")
			}

			label variable `vname' "`vlabel'"

		}

		// === Select One (type 2) ===
		else if `qtype' == 2 {

			// Get non-special choice values for this list
			frame `choices' {
				levelsof real_value if list_name == "`vallabel'" ///
					& !inlist(real_value, `dk', `refused', `other'), local(cvals)
				local n_choices = `r(r)'
				// Check if special codes exist in this list
				count if list_name == "`vallabel'" & inlist(real_value, `dk', `refused', `other')
				local has_special = `r(N)' > 0
			}

			if `n_choices' > 0 {
				// Create numeric variable
				gen `vname' = .

				// Build array of non-special values
				local ci = 0
				foreach cv in `cvals' {
					local ++ci
					local cval_`ci' = `cv'
				}

				// Randomly assign from non-special values
				tempvar _trand
				gen double `_trand' = runiform()
				forvalues ci = 1/`n_choices' {
					local lower = (`ci' - 1) / `n_choices'
					local upper = `ci' / `n_choices'
					replace `vname' = `cval_`ci'' ///
						if `_trand' >= `lower' & `_trand' < `upper'
				}
				replace `vname' = `cval_1' if missing(`vname')
				drop `_trand'

				// Apply value label (already defined in frame)
				cap label values `vname' `vallabel'

				// Inject special missing codes (~5% total, only if list has them)
				if `has_special' {
					if `dk' != 1 replace `vname' = .d if runiform() < 0.017
					if `refused' != 1 replace `vname' = .r if runiform() < 0.017
					if `other' != 1 replace `vname' = .o if runiform() < 0.017
				}
			}
			else {
				gen `vname' = floor(runiform() * 5) + 1
			}

			label variable `vname' "`vlabel'"

		}

		// === Select Multiple (type 3) ===
		else if `qtype' == 3 {

			frame `choices' {
				levelsof real_value if list_name == "`vallabel'", local(cvals)
				local n_choices = `r(r)'
			}

			if `n_choices' > 0 {

				// Create binary columns for each choice
				foreach cv in `cvals' {
					local clean_cv = subinstr("`cv'", "-", "_", 1)
					gen byte `vname'_`clean_cv' = (runiform() > 0.5)
				}

				// Ensure at least one is selected per observation
				tempvar _tany
				gen byte `_tany' = 0
				foreach cv in `cvals' {
					local clean_cv = subinstr("`cv'", "-", "_", 1)
					replace `_tany' = 1 if `vname'_`clean_cv' == 1
				}
				// If none selected, select the first
				local first_cv : word 1 of `cvals'
				local clean_first = subinstr("`first_cv'", "-", "_", 1)
				replace `vname'_`clean_first' = 1 if `_tany' == 0
				drop `_tany'

				// Build concatenated string column
				gen str244 `vname' = ""
				foreach cv in `cvals' {
					local clean_cv = subinstr("`cv'", "-", "_", 1)
					replace `vname' = `vname' + " " + "`cv'" if `vname'_`clean_cv' == 1

					// Label binary columns
					frame `choices' {
						levelsof label if list_name == "`vallabel'" & real_value == `cv', ///
							clean local(cv_label)
					}
					cap label variable `vname'_`clean_cv' "#{`vname'}: `cv_label'"
				}
				replace `vname' = strtrim(`vname')

			}
			else {
				gen str1 `vname' = "1"
			}

			label variable `vname' "`vlabel'"

		}

		// === Numeric (type 4) ===
		else if `qtype' == 4 {

			// Parse constraints for bounds
			local lo = 0
			local hi = 100

			if "`vconstraint'" != "" {
				// Try to extract lower bound: .>=N or .>N
				cap local lo_match = ustrregexs(1) ///
					if ustrregexm("`vconstraint'", "\.[ ]*>=?[ ]*([0-9]+)")
				if !_rc & "`lo_match'" != "" {
					local lo = `lo_match'
				}
				// Try to extract upper bound: .<=N or .<N
				cap local hi_match = ustrregexs(1) ///
					if ustrregexm("`vconstraint'", "\.[ ]*<=?[ ]*([0-9]+)")
				if !_rc & "`hi_match'" != "" {
					local hi = `hi_match'
				}
			}

			if "`vtype'" == "integer" | "`vtype'" == "calculate" {
				gen `vname' = floor(runiform() * (`hi' - `lo' + 1)) + `lo'
			}
			else if "`vtype'" == "decimal" {
				gen double `vname' = runiform() * (`hi' - `lo') + `lo'
			}
			else {
				// Default numeric
				gen `vname' = floor(runiform() * (`hi' - `lo' + 1)) + `lo'
			}

			label variable `vname' "`vlabel'"

			// Randomly assign extended missing values (~5% total)
			if `dk' != 1 replace `vname' = .d if runiform() < 0.017
			if `refused' != 1 replace `vname' = .r if runiform() < 0.017
			if `other' != 1 replace `vname' = .o if runiform() < 0.017

		}

		// === Date (type 5) ===
		else if `qtype' == 5 {

			gen long `vname' = date("2024-01-01", "YMD") + floor(runiform() * 730)
			format `vname' %td
			label variable `vname' "`vlabel'"

		}

		// === Datetime (type 6) ===
		else if `qtype' == 6 {

			// Skip if already created as metadata
			cap confirm variable `vname'
			if !_rc continue

			gen double `vname' = clock("2024-01-01 00:00:00", "YMDhms") + ///
				floor(runiform() * 365 * 24 * 3600) * 1000
			format `vname' %tc
			label variable `vname' "`vlabel'"

		}

		// === GPS (type 7) ===
		else if `qtype' == 7 {

			// Sierra Leone approximate coordinates (center: 8.5, -11.8)
			gen double `vname'Latitude = 7 + runiform() * 3
			gen double `vname'Longitude = -13 + runiform() * 3
			gen double `vname'Altitude = runiform() * 500
			gen double `vname'Accuracy = runiform() * 50

			label variable `vname'Latitude "`vlabel': Latitude"
			label variable `vname'Longitude "`vlabel': Longitude"
			label variable `vname'Altitude "`vlabel': Altitude"
			label variable `vname'Accuracy "`vlabel': Accuracy"

		}

	} // end frame maindata

} // end forvalues

*----------------------------------------------------------------------
* 6c. Apply relevancy conditions to main dataset
*----------------------------------------------------------------------

noisily display as text "Applying relevancy conditions..."

cwf `qs'
forvalues i = 1/`N_qs' {

	if question_type[`i'] == -111 continue
	if repeat_group[`i'] != 0 continue

	local vname = name[`i']
	local qtype = question_type[`i']
	local vrel = relevant[`i']
	local vgroup = group[`i']

	if "`vname'" == "" | "`vname'" == "." continue

	// 1. Apply the variable's own relevancy condition
	cwf `maindata'
	_cto2_dummy_apply_rel `vname' `qtype' "`vrel'"
	cwf `qs'

	// 2. Walk up the standard group chain, applying each condition separately
	if `vgroup' > 0 & `n_groups' > 0 {
		local gw = `vgroup'
		while `gw' > 0 {
			// Look up this group's condition in the groups frame
			local gcond ""
			local gw_next = 0
			frame `groups' {
				forvalues _gr = 1/`c(N)' {
					if gtype[`_gr'] == 1 & gindex[`_gr'] == `gw' {
						local gcond = conditions[`_gr']
						local gw_next = within[`_gr']
						continue, break
					}
				}
			}
			if "`gcond'" != "" & "`gcond'" != "." {
				cwf `maindata'
				_cto2_dummy_apply_rel `vname' `qtype' "`gcond'"
				cwf `qs'
			}
			local gw = `gw_next'
		}
	}

}

*----------------------------------------------------------------------
* 6d. Generate repeat group datasets
*----------------------------------------------------------------------

if `n_repeats' > 0 {

	noisily display as text "Generating repeat group datasets..."

	// Determine nesting order and process outermost first
	frame `groups' {

		// Only work with repeat groups
		levelsof gindex if gtype == 2, clean local(repeat_indices)

	}

	foreach ri in `repeat_indices' {

		frame `groups' {
			// Get repeat group info - find row number for this repeat index
			local grow = 0
			forvalues _gr = 1/`c(N)' {
				if gtype[`_gr'] == 2 & gindex[`_gr'] == `ri' {
					local grow = `_gr'
					continue, break
				}
			}
			local rg_name = gname[`grow']
			local rg_rc = repeat_count[`grow']
			local rg_within = within[`grow']
		}

		// Determine parent frame
		if `rg_within' == 0 {
			local parent_frame `maindata'
		}
		else {
			local parent_frame `frame_rg_`rg_within''
		}

		// Resolve repeat count expression
		local rc_expr "`rg_rc'"

		// Check if it's a fixed integer
		local is_fixed = regexm("`rc_expr'", "^[0-9]+$")

		// Check if it references a variable: #{varname} or just a number
		local rc_var ""
		local is_count_sel = 0
		if !`is_fixed' {
			// Check for count-selected pattern
			local is_count_sel = regexm("`rc_expr'", "count-selected")
			if `is_count_sel' {
				// Extract variable name from count-selected(#{var})
				local rc_var = ustrregexra("`rc_expr'", ///
					"count-selected\(#\{(\w+)\}\)", "$1")
			}
			else {
				// Extract variable name from #{var}
				local rc_var = ustrregexra("`rc_expr'", "#\{(\w+)\}", "$1")
				local rc_var = strtrim("`rc_var'")
			}
		}

		// Create the repeat group dataset
		tempname frame_rg_`ri'
		frame create `frame_rg_`ri''

		frame `parent_frame' {
			local parent_N = _N
		}

		// Build the expanded dataset observation by observation
		frame `frame_rg_`ri'' {

			// Start with 0 obs, will expand
			gen str50 KEY = ""
			gen str50 PARENT_KEY = ""
			gen long _parent_obs = .
			gen long _rep_index = .

			// Define all value labels in this frame
			foreach listo in `all_lists' {
				cap `lab_cmd_`listo''
			}

		}

		// For each parent observation, determine repeat count and add rows
		forvalues pobs = 1/`parent_N' {

			local this_rc = 0

			if `is_fixed' {
				local this_rc = `rc_expr'
			}
			else if `is_count_sel' {
				// Count selected: count binary columns that are 1
				frame `parent_frame' {
					local this_rc = 0
					// Find numeric binary columns for this select_multiple
					cap ds `rc_var'_*, has(type numeric)
					if !_rc {
						foreach bv in `r(varlist)' {
							if `bv'[`pobs'] == 1 local ++this_rc
						}
					}
					if `this_rc' == 0 local this_rc = 1
				}
			}
			else if "`rc_var'" != "" {
				// Variable reference
				frame `parent_frame' {
					cap local this_rc = `rc_var'[`pobs']
					if _rc | missing(`this_rc') {
						local this_rc = floor(runiform() * `maxreps') + 1
					}
				}
			}
			else {
				// Fallback: random 1-5
				local this_rc = floor(runiform() * 5) + 1
			}

			// Cap at maxreps
			if `this_rc' > `maxreps' local this_rc = `maxreps'
			if `this_rc' < 0 local this_rc = 0

			// Get parent KEY
			frame `parent_frame' {
				local pkey = KEY[`pobs']
			}

			// Add rows to repeat group frame
			if `this_rc' > 0 {
				frame `frame_rg_`ri'' {
					local old_N = _N
					local new_N = `old_N' + `this_rc'
					set obs `new_N'

					forvalues j = 1/`this_rc' {
						local row = `old_N' + `j'
						replace PARENT_KEY = "`pkey'" in `row'
						replace KEY = "`pkey'/`rg_name'[`j']" in `row'
						replace _parent_obs = `pobs' in `row'
						replace _rep_index = `j' in `row'
					}
				}
			}

		} // end parent obs loop

		// Now generate variables within this repeat group
		frame `frame_rg_`ri'' {
			local rg_N = _N
		}

		if `rg_N' == 0 {
			noisily display as text "  Warning: repeat group `rg_name' has 0 observations, skipping."
			continue
		}

		noisily display as text "  Generating `rg_name' (`rg_N' observations)..."

		// Walk through survey rows for variables in this repeat group
		cwf `qs'
		forvalues i = 1/`N_qs' {

			if question_type[`i'] == -111 continue
			if question_type[`i'] == -222 continue
			if repeat_group[`i'] != `ri' continue

			local vname = name[`i']
			local qtype = question_type[`i']
			local vtype = type1[`i']
			local vlabel = labelStata[`i']
			local vallabel = type2[`i']
			local vconstraint = constraint[`i']
			local vcalculation = calculation[`i']

			if "`vname'" == "" | "`vname'" == "." continue

			frame `frame_rg_`ri'' {

				cap confirm variable `vname'
				if !_rc continue

				// === String ===
				if `qtype' == 1 {
					if "`vtype'" == "calculate" {
						local calc "`vcalculation'"
						local calc = ustrregexra("`calc'", "#\{(\w+)\}", "$1")
						local calc = subinstr("`calc'", "if(", "cond(", .)
						local calc = ustrregexra("`calc'", "([^!<>=])=([^=])", "$1==$2")
						cap gen str80 `vname' = `calc'
						if _rc gen str30 `vname' = "calc_" + string(_n)
					}
					else {
						gen str30 `vname' = "text_" + string(_n, "%04.0f") + ///
							"_" + string(floor(runiform() * 9999), "%04.0f")
					}
					label variable `vname' "`vlabel'"
				}

				// === Select One ===
				else if `qtype' == 2 {
					frame `choices' {
						levelsof real_value if list_name == "`vallabel'" ///
							& !inlist(real_value, `dk', `refused', `other'), local(cvals)
						local n_choices = `r(r)'
						count if list_name == "`vallabel'" & inlist(real_value, `dk', `refused', `other')
						local has_special = `r(N)' > 0
					}
					if `n_choices' > 0 {
						gen `vname' = .
						local ci = 0
						foreach cv in `cvals' {
							local ++ci
							local cval_`ci' = `cv'
						}
						tempvar _trand
						gen double `_trand' = runiform()
						forvalues ci = 1/`n_choices' {
							local lower = (`ci' - 1) / `n_choices'
							local upper = `ci' / `n_choices'
							replace `vname' = `cval_`ci'' ///
								if `_trand' >= `lower' & `_trand' < `upper'
						}
						replace `vname' = `cval_1' if missing(`vname')
						drop `_trand'
						cap label values `vname' `vallabel'
						// Inject special codes (~5% total)
						if `has_special' {
							if `dk' != 1 replace `vname' = .d if runiform() < 0.017
							if `refused' != 1 replace `vname' = .r if runiform() < 0.017
							if `other' != 1 replace `vname' = .o if runiform() < 0.017
						}
					}
					else {
						gen `vname' = floor(runiform() * 5) + 1
					}
					label variable `vname' "`vlabel'"
				}

				// === Select Multiple ===
				else if `qtype' == 3 {
					frame `choices' {
						levelsof real_value if list_name == "`vallabel'", local(cvals)
						local n_choices = `r(r)'
					}
					if `n_choices' > 0 {
						foreach cv in `cvals' {
							local clean_cv = subinstr("`cv'", "-", "_", 1)
							gen byte `vname'_`clean_cv' = (runiform() > 0.5)
						}
						gen byte _any_`vname' = 0
						foreach cv in `cvals' {
							local clean_cv = subinstr("`cv'", "-", "_", 1)
							replace _any_`vname' = 1 if `vname'_`clean_cv' == 1
						}
						local first_cv : word 1 of `cvals'
						local clean_first = subinstr("`first_cv'", "-", "_", 1)
						replace `vname'_`clean_first' = 1 if _any_`vname' == 0
						drop _any_`vname'
						gen str244 `vname' = ""
						foreach cv in `cvals' {
							local clean_cv = subinstr("`cv'", "-", "_", 1)
							replace `vname' = `vname' + " " + "`cv'" if `vname'_`clean_cv' == 1
							frame `choices' {
								levelsof label if list_name == "`vallabel'" & real_value == `cv', ///
									clean local(cv_label)
							}
							cap label variable `vname'_`clean_cv' "#{`vname'}: `cv_label'"
						}
						replace `vname' = strtrim(`vname')
					}
					else {
						gen str1 `vname' = "1"
					}
					label variable `vname' "`vlabel'"
				}

				// === Numeric ===
				else if `qtype' == 4 {
					local lo = 0
					local hi = 100
					if "`vconstraint'" != "" {
						cap local lo_match = ustrregexs(1) ///
							if ustrregexm("`vconstraint'", "\.[ ]*>=?[ ]*([0-9]+)")
						if !_rc & "`lo_match'" != "" local lo = `lo_match'
						cap local hi_match = ustrregexs(1) ///
							if ustrregexm("`vconstraint'", "\.[ ]*<=?[ ]*([0-9]+)")
						if !_rc & "`hi_match'" != "" local hi = `hi_match'
					}
					if "`vtype'" == "decimal" {
						gen double `vname' = runiform() * (`hi' - `lo') + `lo'
					}
					else {
						gen `vname' = floor(runiform() * (`hi' - `lo' + 1)) + `lo'
					}
					label variable `vname' "`vlabel'"
					// ~5% total extended missing
					if `dk' != 1 replace `vname' = .d if runiform() < 0.017
					if `refused' != 1 replace `vname' = .r if runiform() < 0.017
					if `other' != 1 replace `vname' = .o if runiform() < 0.017
				}

				// === Date ===
				else if `qtype' == 5 {
					gen long `vname' = date("2024-01-01", "YMD") + floor(runiform() * 730)
					format `vname' %td
					label variable `vname' "`vlabel'"
				}

				// === Datetime ===
				else if `qtype' == 6 {
					cap confirm variable `vname'
					if !_rc continue
					gen double `vname' = clock("2024-01-01 00:00:00", "YMDhms") + ///
						floor(runiform() * 365 * 24 * 3600) * 1000
					format `vname' %tc
					label variable `vname' "`vlabel'"
				}

				// === GPS ===
				else if `qtype' == 7 {
					gen double `vname'Latitude = 7 + runiform() * 3
					gen double `vname'Longitude = -13 + runiform() * 3
					gen double `vname'Altitude = runiform() * 500
					gen double `vname'Accuracy = runiform() * 50
					label variable `vname'Latitude "`vlabel': Latitude"
					label variable `vname'Longitude "`vlabel': Longitude"
					label variable `vname'Altitude "`vlabel': Altitude"
					label variable `vname'Accuracy "`vlabel': Accuracy"
				}

			} // end frame

		} // end forvalues

		// Apply relevancy conditions for this repeat group
		cwf `qs'
		forvalues i = 1/`N_qs' {

			if question_type[`i'] == -111 continue
			if repeat_group[`i'] != `ri' continue

			local vname = name[`i']
			local qtype = question_type[`i']
			local vrel = relevant[`i']
			local vgroup = group[`i']

			if "`vname'" == "" | "`vname'" == "." continue

			// Apply variable's own condition
			cwf `frame_rg_`ri''
			_cto2_dummy_apply_rel `vname' `qtype' "`vrel'"
			cwf `qs'

			// Walk up standard group chain
			if `vgroup' > 0 & `n_groups' > 0 {
				local gw = `vgroup'
				while `gw' > 0 {
					local gcond ""
					local gw_next = 0
					frame `groups' {
						forvalues _gr = 1/`c(N)' {
							if gtype[`_gr'] == 1 & gindex[`_gr'] == `gw' {
								local gcond = conditions[`_gr']
								local gw_next = within[`_gr']
								continue, break
							}
						}
					}
					if "`gcond'" != "" & "`gcond'" != "." {
						cwf `frame_rg_`ri''
						_cto2_dummy_apply_rel `vname' `qtype' "`gcond'"
						cwf `qs'
					}
					local gw = `gw_next'
				}
			}

		}

		// Save repeat group dataset
		frame `frame_rg_`ri'' {

			// Drop internal helper variables
			cap drop _parent_obs
			cap drop _rep_index

			// Value labels already defined when frame was created

			local rg_savepath "`savefolder'/`rg_name'.dta"

			cap confirm file "`rg_savepath'"
			if !_rc & "`replace'" == "" {
				noisily display as error ///
					"file `rg_savepath' already exists. Use option {bf:replace}."
				continue
			}

			compress
			save "`rg_savepath'", `replace'

			noisily display as text "  Saved: `rg_savepath' (`=_N' obs, `=c(k)' vars)"

		}

	} // end repeat group loop

} // end if n_repeats > 0

*===============================================================================
* 	Phase 7: Apply Labels & Save Main Dataset
*===============================================================================

noisily display as text "Saving main dataset..."

frame `maindata' {

	// Value labels already defined when frame was created

	// Check for save path
	local main_savepath "`savefolder'/`form_id'.dta"

	cap confirm file "`main_savepath'"
	if !_rc & "`replace'" == "" {
		noisily display as error ///
			"file `main_savepath' already exists. Use option {bf:replace}."
		exit 602
	}

	compress
	save "`main_savepath'", `replace'

	noisily display as text "  Saved: `main_savepath' (`=_N' obs, `=c(k)' vars)"

}

*===============================================================================
* 	Summary
*===============================================================================

noisily display as text ""
noisily display as text "{hline 60}"
noisily display as text "cto2_dummy complete."
noisily display as text "{hline 60}"
noisily display as text "  Instrument:   `instname'"
noisily display as text "  Form ID:      `form_id'"
noisily display as text "  Output:       `savefolder'"
noisily display as text "  Main dataset: `form_id'.dta (`nobs' obs)"

if `n_repeats' > 0 {
	noisily display as text "  Repeat groups: `n_repeats'"
	frame `groups' {
		forvalues r = 1/`c(N)' {
			if gtype[`r'] == 2 {
				noisily display as text "    - `=gname[`r']'"
			}
		}
	}
}

noisily display as text "{hline 60}"

// Clean up frames
frame change `original_frame'
restore

} // end qui

end
