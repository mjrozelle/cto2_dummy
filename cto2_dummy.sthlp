{smcl}
{* *! version 0.0.1  March 2026}{...}
{viewerjumpsto "Syntax" "cto2_dummy##syntax"}{...}
{viewerjumpsto "Description" "cto2_dummy##description"}{...}
{viewerjumpto "Options" "cto2_dummy##options"}{...}
{viewerjumpto "Examples" "cto2_dummy##examples"}{...}
{viewerjumpto "Author" "cto2_dummy##author"}{...}
{title:Title}

{phang}
{bf:cto2_dummy} {hline 2} Generate dummy datasets from SurveyCTO/ODK instrument definitions


{marker syntax}{...}
{title:Syntax}

{p 8 17 2}
{cmdab:cto2_dummy}
{cmd:,}
{cmdab:inst:name(}{it:filepath}{cmd:)}
{cmdab:save:folder(}{it:filepath}{cmd:)}
[{it:options}]

{synoptset 25 tabbed}{...}
{synopthdr}
{synoptline}
{syntab:Required}
{synopt:{opt inst:name(filepath)}}path to .xlsx SurveyCTO/ODK instrument{p_end}
{synopt:{opt save:folder(filepath)}}folder where .dta files will be saved{p_end}

{syntab:Optional}
{synopt:{opt dk(integer)}}value for "don't know" responses; default is {cmd:-999}{p_end}
{synopt:{opt other(integer)}}value for "other (specify)" responses; default is {cmd:-555}{p_end}
{synopt:{opt refused(integer)}}value for "refused" responses; default is {cmd:-777}{p_end}
{synopt:{opt nobs(integer)}}number of observations in main dataset; default is {cmd:1000}{p_end}
{synopt:{opt maxreps(integer)}}maximum repetitions per repeat group; default is {cmd:10}{p_end}
{synopt:{opt replace}}overwrite existing .dta files{p_end}
{synoptline}


{marker description}{...}
{title:Description}

{pstd}
{cmd:cto2_dummy} reads a SurveyCTO or ODK .xlsx survey instrument and generates
dummy Stata datasets (.dta) that mirror the structure of actual survey data
without containing any real-world values. This allows researchers to share
dataset structures for code development without exposing private data.

{pstd}
The program creates one main dataset (named after the form_id in the settings
sheet) and one dataset per repeat group (named after the repeat group). All
datasets are saved to the specified {opt savefolder}.

{pstd}
{bf:Features:}

{phang2}{bf:Variable types:} Handles all standard SurveyCTO question types
including text, integer, decimal, select_one, select_multiple, date, datetime,
geopoint, and calculate fields.{p_end}

{phang2}{bf:Value labels:} Applies value labels from the choices sheet to
select_one variables.{p_end}

{phang2}{bf:Select multiple:} Creates binary indicator columns (var_1, var_2, etc.)
for each choice option, plus a concatenated string column.{p_end}

{phang2}{bf:Repeat groups:} Generates separate datasets for each repeat group
with observation counts respecting the survey's repeat_count logic.{p_end}

{phang2}{bf:Relevancy:} Parses relevancy conditions and sets irrelevant
observations to missing (best-effort).{p_end}

{phang2}{bf:Constraints:} Extracts min/max bounds from constraint expressions
to generate values within valid ranges.{p_end}

{phang2}{bf:Metadata:} Includes standard SurveyCTO metadata fields (KEY,
SubmissionDate, formdef_version, starttime, endtime, deviceid).{p_end}

{phang2}{bf:Special codes:} Randomly assigns extended missing values (.d, .o, .r)
at low frequency for don't know, other, and refused responses.{p_end}


{marker options}{...}
{title:Options}

{dlgtab:Required}

{phang}
{opt instname(filepath)} specifies the path to the .xlsx SurveyCTO or ODK
survey instrument. The file must contain at minimum a {it:survey} sheet and a
{it:choices} sheet.

{phang}
{opt savefolder(filepath)} specifies the folder where all generated .dta files
will be saved. The folder will be created if it does not exist.

{dlgtab:Optional}

{phang}
{opt dk(integer)} specifies the numeric value used in the survey instrument to
represent "don't know" responses. Default is {cmd:-999}. These values are mapped
to Stata's extended missing value {cmd:.d}.

{phang}
{opt other(integer)} specifies the numeric value used for "other (specify)"
responses. Default is {cmd:-555}. Mapped to {cmd:.o}.

{phang}
{opt refused(integer)} specifies the numeric value used for "refused to answer"
responses. Default is {cmd:-777}. Mapped to {cmd:.r}.

{phang}
{opt nobs(integer)} specifies the number of observations to generate in the
main (survey-level) dataset. Default is {cmd:1000}.

{phang}
{opt maxreps(integer)} specifies the maximum number of repetitions per parent
observation in repeat groups. This prevents dataset explosion when repeat_count
variables have large values. Default is {cmd:10}.

{phang}
{opt replace} permits overwriting existing .dta files in the save folder.


{marker examples}{...}
{title:Examples}

{pstd}Basic usage:{p_end}
{phang2}{cmd:. cto2_dummy, inst("survey_instrument.xlsx") savefolder("./dummy_data") replace}{p_end}

{pstd}With custom special codes:{p_end}
{phang2}{cmd:. cto2_dummy, inst("${instruments}/baseline.xlsx") savefolder("${data}/dummy") dk(-77) other(-55) refused(-99) replace}{p_end}

{pstd}Fewer observations:{p_end}
{phang2}{cmd:. cto2_dummy, inst("endline.xlsx") savefolder("./output") nobs(500) replace}{p_end}


{marker author}{...}
{title:Author}

{pstd}
Michael Rozelle{break}
Wageningen University & Research{break}
michael.rozelle@wur.nl

{pstd}
Part of the {bf:cto2} ecosystem for SurveyCTO data management.


{title:Requirements}

{pstd}
Stata 16 or later (requires frames).
No external dependencies.


{title:Also see}

{psee}
{helpb cto2} (if installed) - Import and clean SurveyCTO data
{p_end}
