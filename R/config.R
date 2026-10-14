# Configuration ----------------------------------------------------------------

.config_defaults <- function() {
  list(
    project = list(name = "gbif_area_assessment"),
    input = list(area = list(mode = NULL, path = NULL, layer = NULL,
                             id_column = NULL, fix_invalid = FALSE)),
    gbif = list(
      filters = list(),
      query = list(method = "search", download_wait_minutes = 720, download_poll_seconds = 30,
                   keep_download_zip = FALSE, max_records = 100000L, page_size = 300L, max_retries = 3L,
                   retry_wait_seconds = 5, max_filter_combinations = 50L,
                   max_wkt_chars = 8000L),
      cache = list(enabled = TRUE, directory = "data/cache/gbif",
                   use_cached = TRUE, refresh = FALSE)
    ),
    analysis = list(density_cell_km = 5, top_n = 10L, low_coverage_pct = 20,
                    metric_crs = "auto", max_map_points = 50000L),
    output = list(directory = "results", write_records_layer = TRUE),
    logging = list(level = "INFO")
  )
}

#' Read the YAML configuration file
#'
#' @param path Path to the YAML file.
#' @return The raw configuration as a list.
#' @export
read_config <- function(path) {
  if (!file.exists(path)) abort_config("file not found: ", path)
  cfg <- tryCatch(yaml::yaml.load(paste(readLines(path, warn = FALSE, encoding = "UTF-8"), collapse = "\n")),
                  error = function(e) abort_config("invalid YAML in ", path, ": ", conditionMessage(e)))
  if (!is.list(cfg)) abort_config("configuration must be a YAML mapping")
  cfg
}

.check_flag <- function(x, name) {
  if (!is.logical(x) || length(x) != 1 || is.na(x)) abort_config(name, " must be true or false")
}

.check_number <- function(x, name, min = -Inf, max = Inf, integer = FALSE) {
  if (!is.numeric(x) || length(x) != 1 || is.na(x) || x < min || x > max ||
      (integer && x != round(x))) {
    abort_config(name, " must be ", if (integer) "an integer" else "a number",
                 " between ", min, " and ", max)
  }
}

#' Validate and complete the configuration
#'
#' Fills defaults, validates every section (including GBIF filters) and
#' resolves paths relative to the project root.
#'
#' @param cfg Raw configuration list from [read_config()].
#' @param root Project root directory.
#' @return A normalised configuration list with `paths` and
#'   `gbif$filters_normalized` added.
#' @export
validate_config <- function(cfg, root) {
  known <- names(.config_defaults())
  extra <- setdiff(names(cfg), known)
  if (length(extra)) lg_warn("Unknown top-level configuration keys ignored: ", paste(extra, collapse = ", "))
  cfg <- utils::modifyList(.config_defaults(), cfg[intersect(names(cfg), known)])

  # project
  nm <- cfg$project$name
  if (!is.character(nm) || length(nm) != 1 || !nzchar(nm)) abort_config("project.name must be a non-empty string")

  # input
  a <- cfg$input$area
  if (is.null(a$mode) || !a$mode %in% c("gpkg", "draw")) {
    abort_config("input.area.mode must be explicitly set to \"gpkg\" or \"draw\"")
  }
  .check_flag(a$fix_invalid, "input.area.fix_invalid")
  if (a$mode == "gpkg") {
    if (!is.character(a$path) || length(a$path) != 1 || !nzchar(a$path)) {
      abort_config("input.area.path is required when mode = \"gpkg\" (a single GPKG file)")
    }
    if (!grepl("\\.gpkg$", a$path, ignore.case = TRUE)) abort_config("input.area.path must be a .gpkg file")
    if (!file.exists(resolve_path(a$path, root))) {
      abort_config("GPKG not found: ", resolve_path(a$path, root))
    }
  } else if (!is.null(a$path) || !is.null(a$layer)) {
    abort_config("mode = \"draw\" cannot be combined with input.area.path/layer; set them to null")
  }

  # gbif query / cache
  q <- cfg$gbif$query
  if (!is.character(q$method) || length(q$method) != 1 || !q$method %in% c("search", "download")) {
    abort_config("gbif.query.method must be \"search\" or \"download\"")
  }
  .check_number(q$download_wait_minutes, "gbif.query.download_wait_minutes", 1, 10080)
  .check_number(q$download_poll_seconds, "gbif.query.download_poll_seconds", 1, 3600)
  .check_flag(q$keep_download_zip, "gbif.query.keep_download_zip")
  .check_number(q$max_records, "gbif.query.max_records", 1, 100000, TRUE)
  .check_number(q$page_size, "gbif.query.page_size", 1, 300, TRUE)
  .check_number(q$max_retries, "gbif.query.max_retries", 0, 20, TRUE)
  .check_number(q$retry_wait_seconds, "gbif.query.retry_wait_seconds", 0, 600)
  .check_number(q$max_filter_combinations, "gbif.query.max_filter_combinations", 1, 1000, TRUE)
  .check_number(q$max_wkt_chars, "gbif.query.max_wkt_chars", 100, 100000, TRUE)
  ca <- cfg$gbif$cache
  for (k in c("enabled", "use_cached", "refresh")) .check_flag(ca[[k]], paste0("gbif.cache.", k))
  if (!is.character(ca$directory) || length(ca$directory) != 1 || !nzchar(ca$directory)) {
    abort_config("gbif.cache.directory must be a non-empty string")
  }
  if (isTRUE(ca$refresh) && !isTRUE(ca$enabled)) {
    lg_warn("gbif.cache.refresh = true has no effect when the cache is disabled")
  }

  # analysis
  an <- cfg$analysis
  .check_number(an$density_cell_km, "analysis.density_cell_km", 0.001, 10000)
  .check_number(an$top_n, "analysis.top_n", 1, 1000, TRUE)
  .check_number(an$low_coverage_pct, "analysis.low_coverage_pct", 0, 100)
  .check_number(an$max_map_points, "analysis.max_map_points", 100, 5e6, TRUE)
  if (!is.character(an$metric_crs) || length(an$metric_crs) != 1) abort_config("analysis.metric_crs must be a string")

  # output / logging
  if (!is.character(cfg$output$directory) || !nzchar(cfg$output$directory)) {
    abort_config("output.directory must be a non-empty string")
  }
  .check_flag(cfg$output$write_records_layer, "output.write_records_layer")
  cfg$logging$level <- normalise_log_level(cfg$logging$level)

  # filters (validated against rgbif)
  cfg$gbif$filters_normalized <- normalize_gbif_filters(cfg$gbif$filters)
  if (q$method == "download") check_download_filters(cfg$gbif$filters_normalized)

  cfg$paths <- list(
    root = root,
    area = resolve_path(a$path, root),
    cache = resolve_path(ca$directory, root),
    output = resolve_path(cfg$output$directory, root)
  )
  cfg
}
