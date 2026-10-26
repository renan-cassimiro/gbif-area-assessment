# CIDI --- GBIF Occurrence Filtering Module

**Branch:** `feat/gbif-occ-filtering`\
**Base:** the existing `feat/gbif-occ-download` implementation\
**Scope:** independent post-retrieval filtering of cached GBIF
occurrence records, initially by one raster with discrete accepted
values.

## 1. Objective

Implement an independent filtering workflow that consumes existing raw
GBIF cache entries and produces a new, reproducible filtering run with
its own outputs and PDF report. The current GBIF acquisition workflow
must continue to work unchanged.

The first implemented filter is spatial and raster-based: retain an
occurrence if the raster value at its geographic coordinates belongs to
a configurable set of discrete values. Records with coordinates outside
the raster, raster NoData, or otherwise unavailable raster values are
excluded and counted separately.

The architecture must provide a small, explicit extension point for
future quality filters, but this delivery must **not implement
quality-filter rules**.

## 2. Existing application context

The existing R application: - loads modules from `R/` with
`sys.source()` in a private environment; - uses YAML configuration,
`renv`, structured logging, and a per-run output directory; - stores raw
GBIF records in `data/cache/gbif/<cache_key>/records.rds`, with
`meta.yaml` beside them; - stores `area_id`, `cache_key`,
`geometry_wkt`, filters, schema version, and other query metadata in
`meta.yaml`; - caches each queried area separately; - currently produces
descriptive metrics, spatial outputs, plots, and a PDF report through
`run_assessment()`.

Inspect the actual code before editing and preserve its conventions. In
particular, review `R/gbif_cache.R`, `R/gbif_processing.R`,
`R/metrics.R`, `R/plots.R`, `R/report.R`, `R/pipeline.R`, `R/config.R`,
`scripts/run.R`, `config/config.yaml`, and `report/report_template.Rmd`.

Do not reimplement GBIF querying or modify raw cache entries.

## 3. Architectural requirements

### 3.1 Independent entry point

Add a dedicated command-line entry point, recommended:

``` bash
Rscript scripts/filter.R config/filter.yaml
```

It must load the project's `renv` environment and R modules consistently
with `scripts/run.R`, but call a new filtering orchestrator (for
example, `run_filtering()`), not `run_assessment()`.

Running the filtering command must: - never call `rgbif`, submit a GBIF
download, poll the GBIF API, or refresh the GBIF cache; - never modify,
rename, archive, or delete raw cache files; - never require GBIF
credentials; - create a unique, independent filtering run directory; -
write `run_status.yaml` with `completed` or `failed`; - return a
non-zero process exit status on failure; - produce no final PDF when a
fatal error prevents a valid report.

### 3.2 Input: existing cache entries

Read one or more explicit cache-entry directories. Each directory must
contain both `records.rds` and `meta.yaml`. Configure the paths
explicitly in the filtering YAML; paths are relative to the project root
unless absolute.

Example:

``` yaml
input:
  cache_entries:
    - "data/cache/gbif/<cache_key>"
```

Support multiple entries to permit multiple study areas in one filtering
run. For every entry: - validate that both files exist and can be
read; - validate `meta.yaml` has a non-empty `cache_key`, a supported
`cache_schema`, and `area_id`; - verify the metadata key agrees with the
directory name when the directory follows the existing cache layout; -
verify the imported row count equals `meta.yaml$n_records` when that
field is present; - reject duplicate cache entries and ambiguous
duplicate `area_id` values unless the implementation can distinguish
them without silently merging unrelated inputs; - preserve each entry's
`area_id` and cache key in run metadata and summaries; - load the
records as raw inputs, then apply the filtering module's own technical
validation and profiling.

Do not scan the entire cache root and silently choose entries. Input
selection must be explicit and reproducible.

The existing metadata stores `geometry_wkt`. Reuse it to reconstruct
each input area's polygon when valid and needed for existing spatial
metrics. If geometry metadata is absent or invalid, fail with an
actionable error if a requested output requires it; do not invent a
polygon. If an existing helper can safely load an explicit area GPKG
instead, reuse it rather than duplicating geometry logic.

### 3.3 Input immutability

Treat all input cache entries as read-only. Never write derived fields
or filtered records back into `records.rds` or `meta.yaml`. All derived
data must be written under the new filtering run directory.

## 4. Raster filter: version 1

### 4.1 Configuration

Create a dedicated filtering configuration, recommended
`config/filter.yaml`. Keep it separate from `config/config.yaml` so the
existing acquisition/evaluation command does not change behavior.

Suggested schema:

``` yaml
project:
  name: "gbif_area_assessment"

input:
  cache_entries:
    - "data/cache/gbif/<cache_key>"

filters:
  spatial:
    raster:
      enabled: true
      path: "data/input/floodplain_mask.tif"
      accepted_values: [1, 3]

analysis:
  top_n: 10
  density_cell_km: 5
  metric_crs: "auto"
  max_map_points: 50000

output:
  directory: "results/filtering"

logging:
  level: "INFO"
```

This is a proposed schema; align names and defaults with the codebase
during implementation. The example cache key and raster path are
placeholders and must not be treated as real files.

Configuration requirements: - exactly one raster per run in this
version; - only discrete exact values are supported; do not add ranges,
thresholds, multiple rasters, or AND/OR combinations; -
`accepted_values` must be a non-empty vector of finite numeric values or
a vector of discrete string/category values, consistent with the
raster's data type; - reject malformed configuration, an empty
accepted-value list, missing files, unsupported raster types, and
invalid values with clear errors; - validate that the raster has a
defined CRS and at least one readable layer/band; - resolve relative
paths against the project root; - log the effective configuration.

The raster must use **EPSG:4326**. Validate the raster CRS before
processing and stop with a clear error if its CRS is missing or is not
EPSG:4326. Occurrence coordinates are longitude/latitude (EPSG:4326), so
extract raster values directly from those coordinates after confirming
the CRS. Do not reproject the raster or occurrence points automatically.

Use `terra` for raster reading and point-value extraction unless
inspection reveals an already-installed suitable abstraction. Add it to
`DESCRIPTION` and update the lockfile/environment through the project's
normal dependency workflow. Do not edit `renv.lock` by hand.

### 4.2 Pixel extraction and keep/drop rule

For each technically valid occurrence: 1. use `decimalLongitude` and
`decimalLatitude` as coordinates; 2. create point coordinates in
EPSG:4326; 3. extract the raster cell value at the corresponding
location, correctly handling CRS; 4. retain the record only if its
extracted value matches one of `accepted_values`.

Use exact discrete-value membership, not interval comparison or fuzzy
numeric matching. Ensure factor/categorical raster values are handled
consistently with their stored values; document whether comparison is
against raster cell codes or category labels, and do not silently mix
the two. Prefer cell codes for version 1 unless the existing raster
library behavior makes this unsafe.

Exclude and count separately: - records outside the raster extent; -
records landing on NoData / `NA` cells; - records whose raster value is
valid but not in `accepted_values`; - records removed by pre-filter
technical validation (e.g., missing/non-numeric or out-of-range
coordinates), where applicable.

Avoid opening/reading the raster once per occurrence. Open it once and
perform vectorized extraction or chunked extraction if needed for large
datasets. Preserve all original occurrence columns for retained records,
adding only derived columns in separate tables/objects as needed.

### 4.3 Technical validation

Reuse `validate_records()` or factor out shared safe logic where
practical, but do not call acquisition or mutate its cache. Be explicit
about whether the "before" profile represents: - raw records as stored
in cache; and - technically valid records eligible for raster
extraction.

The report must show the raw input count and the count after technical
validation, so records removed before raster extraction are not hidden.
Keep technical validation removals distinct from raster-filter removals.

## 5. Filter pipeline and future extensibility

Implement a filtering orchestrator with a clear sequence:

1.  Read and validate filtering configuration.
2.  Create unique run directory and initialize file logging.
3.  Load explicit cache entries and their metadata.
4.  Calculate the **raw input profile**.
5.  Apply shared technical validation and report technical removals.
6.  Calculate the **pre-filter eligible profile** (records eligible to
    be tested by the raster filter).
7.  Execute enabled filters in a deterministic order.
8.  Calculate the **post-filter profile** using the same profile metrics
    as the pre-filter profile.
9.  Write tables and spatial outputs.
10. Render the independent PDF report.
11. Write completion status and run metadata.

Create a small filter registry/contract rather than hard-coding all
filter behavior directly into the orchestrator. Each implemented filter
should have: - a stable identifier and category (initially `spatial`); -
configuration validation; - a function that receives the current records
and relevant configuration/context; - retained records plus a structured
removal summary; - parameters and execution metadata suitable for
reporting.

For this version, register and implement only `spatial.raster`. The
architecture should make a future `quality` category possible without
implementing placeholder quality rules, unused settings, or speculative
quality metrics now.

Filters run sequentially. For each stage, report input count, retained
count, removed count, and reason breakdown. Stage-level counts must be
unambiguous: the denominator for a filter is the records passed into
that filter, after previous stages. Do not sum per-stage removals and
imply they are necessarily unique across all criteria.

## 6. Before/after profiling and outputs

The filtering run must create its own directory under the configured
filtering output directory, for example:

``` text
results/filtering/
└── run_YYYYMMDD_HHMMSS/
    ├── config_original.yaml
    ├── config_effective.yaml
    ├── run_status.yaml
    ├── logs/
    │   └── run_YYYYMMDD_HHMMSS.log
    ├── tables/
    │   ├── input_entries.csv
    │   ├── profile_raw.csv
    │   ├── profile_before_filter.csv
    │   ├── profile_after_filter.csv
    │   ├── filter_summary.csv
    │   ├── removed_records.csv
    │   └── run_context.rds
    ├── spatial/
    │   └── gbif_filtered_records.gpkg
    ├── figures/
    └── report/
        └── filtering_report.pdf
```

Adjust output names to repository conventions if useful, but preserve
the separation of raw profile, pre-filter profile, post-filter profile,
stage summaries, and report.

### 6.1 Comparable profiles

The before and after profiles must use the same metric definitions and
grouping (at minimum by `area_id`) so they can be compared directly.
Reuse existing descriptive metric functions where they accept the
required inputs. Include, where available and valid: - record counts; -
distinct species, genera, and families; - temporal coverage (year range,
records with/without year, records per year); - spatial
coverage/distribution using existing descriptive summaries when the
required area geometry is available.

Do not label distinct observed taxa as true richness or infer ecological
effects. Do not add inferential statistics, rarefaction, bias
correction, or ecological modelling.

The raw profile must describe records as stored in the cache. The
pre-filter profile describes records remaining after technical
validation but before the raster criterion. The post-filter profile
describes records remaining after all enabled filters. Report the
transition counts among these stages.

### 6.2 Removal accounting

Write a structured table with at least: - `area_id`; - `filter_id` or
validation stage; - `reason`; - `n_removed`.

Also write stage summaries with `n_input`, `n_retained`, and
`n_removed`, grouped by area and filter. Explicitly report zero counts
where useful; do not silently omit areas with zero records.

### 6.3 Spatial outputs

Write retained records to a separate output, preferably a GPKG layer,
without modifying the cache. Preserve source attributes. The
raster-derived cell value may be included in the filtered output as a
clearly named derived field (e.g. `raster_value`), but do not overwrite
an original field; if there is a name collision, use a documented safe
name or omit the derived field from the occurrence table and keep it in
a separate table.

Re-use existing plotting/spatial-output functions when practical. For
very large data, respect the existing `max_map_points` plotting limit
and avoid creating unnecessarily duplicated full-size copies in memory.

If there are no records after filtering, complete successfully with a
warning and produce valid empty tables/report; spatial layers that
cannot be written as meaningful empty layers may be omitted with a
warning. A zero-record outcome is not itself a fatal error.

## 7. Independent report

Create a separate report template, recommended
`report/filtering_report_template.Rmd`, and render it to
`report/filtering_report.pdf`. Do not replace or repurpose the existing
acquisition assessment report template.

The report must describe: 1. run identity, timestamp, tool version, Git
state, R/platform/`renv` environment and effective configuration; 2.
source cache entries, `area_id`, cache keys, source query metadata and
input record counts; 3. raster path, raster metadata available (CRS,
resolution, extent, layer/band), accepted discrete values, and filtering
configuration; 4. counts of raw, technically valid/pre-filter, retained,
and removed records; 5. removals by stage and reason, per area; 6.
comparable before/after descriptive profiles; 7. relevant maps/plots
where existing code supports them; 8. warnings, execution timings,
limitations, and whether the run completed successfully.

Make clear that the report describes observed GBIF data availability and
the effect of the configured filters; it does not estimate true
biodiversity or validate the raster's ecological correctness.

The report architecture must be able to list filters by category and
parameters, including future quality filters. In this version, show only
filters that are actually implemented and enabled; do not report
hypothetical filters as applied.

## 8. Logging, provenance, and error handling

Follow existing `logger` conventions and capture warnings in the report.
Log start/end and duration for each major stage.

For each run, record: - filtering run ID and timestamp; - Git commit,
branch, and dirty state when available; - tool version and
R/platform/`renv` information; - effective filtering configuration; -
input cache keys and metadata; - raster file path and a content
fingerprint (prefer MD5 or another available local hash); - raster
properties and accepted values; - input, retained, and removed counts; -
stage timings and warnings.

Never claim reproducibility from path alone if the raster file may have
changed; use a file hash where feasible. Do not include secrets or GBIF
credentials in logs/reports.

On fatal errors, log a clear message, write `run_status.yaml` with
`failed` and the error when the run directory exists, and exit non-zero.
Do not emit a misleading completed report after a fatal error. Preserve
earlier run directories; never overwrite an existing run directory.

## 9. Dependencies and documentation

-   Reuse existing dependencies and helpers where reasonable.
-   If `terra` is added, declare it in `DESCRIPTION` and update the
    environment using the repository's normal `renv`/environment
    workflow; do not hand-edit `renv.lock`.
-   Add roxygen2 documentation to new exported or reusable functions
    according to existing style.
-   Update `README.md` with the independent filtering command,
    configuration, inputs, outputs, and the guarantee that it does not
    contact GBIF.
-   Add a short section to `docs/future_work.md` if needed to
    distinguish the implemented raster filter from planned quality
    filters.
-   Keep code and technical documentation in English, consistent with
    the repository. This CIDI is in Portuguese for implementation
    guidance.

## 10. Files expected to change or be added

Expected additions: - `scripts/filter.R`; - `config/filter.yaml`
(example configuration with placeholder paths clearly documented); - one
or more filtering module files under `R/` (prefer a focused module such
as `R/filtering.R`; split only if the actual implementation warrants
it); - `report/filtering_report_template.Rmd`.

Expected modifications: - `DESCRIPTION` and `renv.lock` only if a new
dependency is required; - `README.md`; - `docs/future_work.md` if
useful.

Avoid unnecessary changes to: - `R/gbif_query.R`; -
`R/gbif_download.R`; - `R/gbif_cache.R`; - `R/pipeline.R` and the
existing assessment report, except for small, justified shared-helper
refactoring.

The existing `scripts/run.R config/config.yaml` workflow must continue
to behave as before.

## 11. Acceptance criteria

The implementation is complete when all of the following are true:

1.  `Rscript scripts/filter.R config/filter.yaml` starts an independent
    filtering run.
2.  The command reads only explicitly configured existing cache entries
    and never contacts the GBIF API or requires credentials.
3.  A missing cache entry, malformed metadata, invalid raster, missing
    CRS, invalid accepted values, or incompatible configuration causes a
    clear controlled failure.
4.  The original `records.rds` and `meta.yaml` files remain
    byte-for-byte unchanged by filtering.
5.  The raster filter accepts only an explicitly identified EPSG:4326 raster; a missing or different CRS fails clearly and no automatic reprojection occurs.
6.  Records on accepted discrete values are retained; records on other
    valid values are excluded.
7.  Out-of-extent and NoData records are excluded and counted
    separately.
8.  Technical validation removals are reported separately from
    raster-filter removals.
9.  Before/after profiles use the same metric definitions and can be
    compared per area.
10. Multiple explicitly selected cache entries preserve their `area_id`
    and are summarized separately.
11. A unique output directory, effective configuration, logs, tables,
    retained-record output, provenance, and independent PDF report are
    produced.
12. Zero retained records produce a valid completed run with a warning
    and an interpretable report.
13. Fatal errors produce `run_status.yaml` with `failed` when possible
    and a non-zero exit code.
14. The future-filter architecture is present as a minimal
    registry/contract, but no quality-filter behavior is implemented.
15. The existing GBIF acquisition/assessment workflow still runs
    unchanged.

## 12. Testing and verification

Although the current CIDI describes no automated tests in the existing
application, this feature must include focused tests or reproducible
test scripts for its critical logic. Prefer `testthat` if adding it is
proportionate; otherwise provide a small deterministic test script under
`scripts/` or `tests/` and document how to run it.

At minimum verify: - synthetic raster with known cell values and points
in accepted, rejected, NoData, and out-of-extent locations; - point
coordinates transformed correctly for a raster in a projected CRS; -
discrete values are matched exactly; - multiple cache entries preserve
area identifiers; - malformed/missing cache and raster inputs fail
clearly; - raw cache files are unchanged after successful and failed
filtering; - empty post-filter result produces a valid report/status; -
a filtering run does not invoke GBIF functions; - existing
`scripts/run.R config/config.yaml` behavior is not regressed.

Do not use live GBIF downloads as a requirement for these tests. Do not
invent successful test results; record only tests actually executed.

## 13. Non-goals

This delivery does not implement: - any quality filter; - multiple
rasters or logical combinations between rasters; - continuous-value
thresholds or intervals; - raster creation, reprojection, resampling, or
ecological validation; - GBIF acquisition, new query predicates, or
cache invalidation; - taxonomic harmonization, deduplication beyond the
existing technical validation, bias correction, rarefaction, species
distribution modelling, or inferential ecological analyses.

## 14. Implementation notes and open specifications

-   Treat the YAML schema above as the intended starting point, but
    inspect and align with actual helper interfaces before coding.
-   Avoid copying the entire acquisition pipeline into the filtering
    module. Reuse small, stable helpers for logging, provenance,
    profiling, plotting, and report rendering where doing so does not
    couple filtering to GBIF queries.
-   Keep raw, technically valid/pre-filter, and post-filter profiles
    distinct; the report must not ambiguously call all three simply
    "before".
-   The `geometry_wkt` stored in existing cache metadata can help
    reconstruct area geometries for per-area spatial summaries. Validate
    it and fail clearly if a requested geometry-dependent product cannot
    be generated.
-   If `validate_records()` is reused, verify that its assumptions about
    `area_id` and duplicate `gbifID` apply to the filtering input. Any
    adaptation should be explicit and must not mutate cache data.
-   Define and document how categorical rasters are interpreted. Version
    1 uses discrete cell codes; category-label matching is not in scope
    unless the actual raster format requires it.
-   If exact hash generation or Git metadata cannot be obtained, record
    the value as unavailable and issue a warning rather than fabricating
    it.
-   Do not claim performance at multi-million-record scale without a
    representative benchmark. Avoid per-point raster I/O and unnecessary
    copies.

## 15. Definition of done

The feature is done when the acceptance criteria are satisfied, the new
independent command and example configuration are documented, the new
report compares data profiles before and after filtering, raw GBIF cache
entries remain unchanged, the existing acquisition workflow is
preserved, and the implementation's actual test results are documented.
