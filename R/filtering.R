# Post-retrieval filtering of cached GBIF records -------------------------------
#
# Independent from acquisition: this module only READS existing cache entries,
# never calls rgbif, never writes inside the cache. See scripts/filter.R.

.SUPPORTED_CACHE_SCHEMAS <- 1L
.RASTER_CHUNK_SIZE <- 500000L

# Filter registry ---------------------------------------------------------------

#' Registry of implemented filters (the extension point for new filters)
#'
#' Each filter is a list with a stable `id`, a `category`, the configuration
#' `name` under `filters.<category>.<name>`, and three functions:
#' \itemize{
#'   \item `validate(node, root)`: validate its configuration node and return
#'     normalised parameters (a plain list, safe to serialise);
#'   \item `apply(records, params)`: receive the current `sf` records (with
#'     `area_id`) and return `list(retained, removed, meta)` where `removed` has
#'     columns `area_id`, `reason`, `n_removed`;
#'   \item `describe(params)`: a data frame (`parameter`, `value`) for reports.
#' }
#' Filters run in registry order (sorted by category, then id). Only
#' `spatial.raster` is implemented in this version; no quality filters exist.
#'
#' @return A named list of filter specifications.
#' @export
filter_registry <- function() {
  reg <- list(
    spatial.raster = list(
      id = "spatial.raster", category = "spatial", name = "raster",
      validate = validate_raster_filter,
      apply = apply_raster_filter,
      describe = describe_raster_filter
    )
  )
  reg[order(vapply(reg, `[[`, "", "category"), vapply(reg, `[[`, "", "id"))]
}

# Configuration -----------------------------------------------------------------

.filter_config_defaults <- function() {
  list(
    project = list(name = "gbif_area_assessment"),
    input = list(cache_entries = NULL),
    filters = list(),
    analysis = list(top_n = 10L, density_cell_km = 5, metric_crs = "auto",
                    max_map_points = 50000L, low_coverage_pct = 20),
    output = list(directory = "results/filtering"),
    logging = list(level = "INFO")
  )
}

#' Validate the filtering configuration
#'
#' Completes defaults, validates inputs, analysis settings and every enabled
#' filter (including opening the raster to check its CRS), and resolves paths
#' against the project root. No GBIF access is involved.
#'
#' @param cfg Raw configuration list from [read_config()].
#' @param root Project root directory.
#' @return A normalised configuration with `paths` (resolved `cache_entries`,
#'   `output`) and `filters_enabled` (list of `list(spec, params)`).
#' @export
validate_filter_config <- function(cfg, root) {
  defaults <- .filter_config_defaults()
  extra <- setdiff(names(cfg), names(defaults))
  if (length(extra)) lg_warn("Unknown top-level configuration keys ignored: ", paste(extra, collapse = ", "))
  cfg <- utils::modifyList(defaults, cfg[intersect(names(cfg), names(defaults))])

  nm <- cfg$project$name
  if (!is.character(nm) || length(nm) != 1 || !nzchar(nm)) abort_config("project.name must be a non-empty string")

  ce <- unlist(cfg$input$cache_entries, use.names = FALSE)
  if (is.null(ce) || length(ce) == 0 || !is.character(ce) || anyNA(ce) || any(!nzchar(ce))) {
    abort_config("input.cache_entries must list one or more cache entry directories (explicit selection; the cache root is never scanned)")
  }
  resolved <- vapply(ce, function(p) normalizePath(resolve_path(p, root), winslash = "/", mustWork = FALSE), "")
  if (anyDuplicated(resolved)) {
    abort_config("input.cache_entries has duplicate entries: ", paste(unique(resolved[duplicated(resolved)]), collapse = ", "))
  }

  an <- cfg$analysis
  .check_number(an$top_n, "analysis.top_n", 1, 1000, TRUE)
  .check_number(an$density_cell_km, "analysis.density_cell_km", 0.001, 10000)
  .check_number(an$max_map_points, "analysis.max_map_points", 100, 5e6, TRUE)
  .check_number(an$low_coverage_pct, "analysis.low_coverage_pct", 0, 100)
  if (!is.character(an$metric_crs) || length(an$metric_crs) != 1) abort_config("analysis.metric_crs must be a string")
  if (!is.character(cfg$output$directory) || !nzchar(cfg$output$directory)) {
    abort_config("output.directory must be a non-empty string")
  }
  cfg$logging$level <- normalise_log_level(cfg$logging$level)

  cfg$filters_enabled <- .resolve_enabled_filters(cfg$filters, root)
  cfg$paths <- list(root = root, cache_entries = unname(resolved),
                    output = resolve_path(cfg$output$directory, root))
  cfg
}

.resolve_enabled_filters <- function(filters, root) {
  reg <- filter_registry()
  cats <- unique(vapply(reg, `[[`, "", "category"))
  if (length(filters) > 0 && (!is.list(filters) || is.null(names(filters)))) {
    abort_config("filters must be a mapping of categories (", paste(cats, collapse = ", "), ")")
  }
  bad_cat <- setdiff(names(filters), cats)
  if (length(bad_cat)) {
    abort_config("unsupported filter categor", if (length(bad_cat) > 1) "ies" else "y", ": ",
                 paste(bad_cat, collapse = ", "), ". Implemented: ", paste(cats, collapse = ", "))
  }
  for (cat in names(filters)) {
    known <- vapply(Filter(function(s) s$category == cat, reg), `[[`, "", "name")
    bad <- setdiff(names(filters[[cat]]), known)
    if (length(bad)) {
      abort_config("unsupported filter(s) in filters.", cat, ": ", paste(bad, collapse = ", "),
                   ". Implemented: ", paste(known, collapse = ", "))
    }
  }
  enabled <- list()
  for (spec in reg) {
    node <- filters[[spec$category]][[spec$name]]
    if (is.null(node)) next
    flag <- if (is.list(node)) node$enabled else NULL
    if (!is.logical(flag) || length(flag) != 1 || is.na(flag)) {
      abort_config("filters.", spec$category, ".", spec$name, ".enabled must be true or false")
    }
    if (!flag) {
      lg_info("Filter ", spec$id, " is disabled in the configuration")
      next
    }
    enabled[[spec$id]] <- list(spec = spec, params = spec$validate(node, root))
  }
  if (length(enabled) == 0) abort_config("no filter is enabled; enable at least one filter (e.g. filters.spatial.raster.enabled: true)")
  enabled
}

# Raster filter -----------------------------------------------------------------

.raster_crs_status <- function(r) {
  wkt <- terra::crs(r)
  if (!nzchar(wkt)) return(list(ok = FALSE, label = "missing"))
  d <- tryCatch(terra::crs(r, describe = TRUE), error = function(e) NULL)
  auth <- if (is.null(d)) "" else toupper(as.character(d$authority[1]))
  code <- if (is.null(d)) "" else toupper(as.character(d$code[1]))
  label <- if (is.null(d)) "unknown" else paste0(auth, ":", code, " (", d$name[1], ")")
  # EPSG:4326 and OGC:CRS84 are the same WGS 84 lon/lat geographic system for raster data
  ok <- (auth == "EPSG" && code == "4326") || (auth == "OGC" && code == "CRS84") ||
    isTRUE(tryCatch(sf::st_crs(wkt) == sf::st_crs(4326), error = function(e) FALSE))
  list(ok = ok, label = label)
}

#' Validate the raster filter configuration and inspect the raster
#'
#' Version 1 supports exactly one raster (EPSG:4326, not reprojected) and exact
#' matching of numeric cell codes. Category labels are not supported.
#'
#' @param node The `filters.spatial.raster` configuration node.
#' @param root Project root directory.
#' @return A list of normalised parameters including raster metadata and an MD5
#'   fingerprint of the raster file.
#' @export
validate_raster_filter <- function(node, root) {
  if (!is.list(node)) abort_config("filters.spatial.raster must be a mapping")
  extra <- setdiff(names(node), c("enabled", "path", "accepted_values"))
  if (length(extra)) {
    abort_config("unsupported raster filter option(s): ", paste(extra, collapse = ", "),
                 ". Version 1 supports only 'path' and 'accepted_values' (exact discrete values; no ranges, thresholds or combinations)")
  }
  p <- node$path
  if (!is.character(p) || length(p) != 1 || is.na(p) || !nzchar(p)) abort_config("filters.spatial.raster.path must be a non-empty string")
  path <- normalizePath(resolve_path(p, root), winslash = "/", mustWork = FALSE)
  if (!file.exists(path) || dir.exists(path)) abort_config("raster file not found: ", path)

  av <- unlist(node$accepted_values, use.names = FALSE)
  if (is.null(av) || length(av) == 0) abort_config("filters.spatial.raster.accepted_values must be a non-empty vector")
  if (is.character(av)) {
    abort_config("accepted_values must be numeric raster cell codes; category-label matching is not supported in this version")
  }
  if (!is.numeric(av) || any(!is.finite(av))) abort_config("accepted_values must contain only finite numeric values")
  av <- unique(as.numeric(av))

  r <- tryCatch(terra::rast(path), error = function(e) abort_config("raster could not be read (", path, "): ", conditionMessage(e)))
  if (terra::nlyr(r) < 1) abort_config("raster has no readable layer: ", path)
  crs <- .raster_crs_status(r)
  if (identical(crs$label, "missing")) abort_config("raster has no CRS defined; it must be EPSG:4326: ", path)
  if (!crs$ok) {
    abort_config("raster CRS is ", crs$label, " but must be EPSG:4326 (the tool does not reproject rasters or occurrence points): ", path)
  }
  if (terra::nlyr(r) > 1) lg_warn("Raster has ", terra::nlyr(r), " layers; only the first layer ('", names(r)[1], "') is used")
  r1 <- r[[1]]
  dtype <- as.character(terra::datatype(r1)[1])
  categorical <- isTRUE(terra::is.factor(r1)[1])
  if (grepl("^FLT", dtype)) {
    lg_warn("Raster datatype is ", dtype, ": matching is exact equality on stored floating-point values")
  }
  if (categorical) {
    lg_info("Categorical raster: accepted_values are matched against raw cell codes, not category labels")
  }
  md5 <- unname(tools::md5sum(path))
  if (is.na(md5)) lg_warn("Could not compute the MD5 fingerprint of ", path)
  if (grepl("\\.(vrt|grd)$", path, ignore.case = TRUE)) {
    lg_warn("The raster is a multi-file format; the MD5 fingerprint covers only the main file")
  }
  e <- as.vector(terra::ext(r1))
  list(
    path = path, accepted_values = av,
    raster = list(md5 = md5, crs = crs$label, nrow = terra::nrow(r1), ncol = terra::ncol(r1),
                  n_layers = terra::nlyr(r), layer = names(r1)[1], datatype = dtype,
                  categorical = categorical, res_x = terra::res(r1)[1], res_y = terra::res(r1)[2],
                  xmin = unname(e["xmin"]), xmax = unname(e["xmax"]), ymin = unname(e["ymin"]), ymax = unname(e["ymax"]))
  )
}

#' Describe the raster filter parameters for reports
#' @param params Output of [validate_raster_filter()].
#' @return A data frame with columns `parameter` and `value`.
#' @export
describe_raster_filter <- function(params) {
  r <- params$raster
  data.frame(
    parameter = c("path", "md5", "layer", "crs", "resolution", "extent (xmin, xmax, ymin, ymax)", "datatype",
                  "accepted_values (raster cell codes)"),
    value = c(params$path, r$md5 %||% NA, r$layer, r$crs, paste(signif(c(r$res_x, r$res_y), 8), collapse = " x "),
              paste(signif(c(r$xmin, r$xmax, r$ymin, r$ymax), 8), collapse = ", "), r$datatype,
              paste(params$accepted_values, collapse = ", ")),
    stringsAsFactors = FALSE
  )
}

.safe_derived_name <- function(name, existing) {
  while (name %in% existing) name <- paste0(name, "_derived")
  name
}

#' Retain records whose raster cell value is in a set of accepted values
#'
#' The raster is opened once and queried in chunks. Coordinates are used as-is
#' (EPSG:4326, validated before). Removals are classified as
#' `outside_raster_extent`, `raster_nodata` or `raster_value_not_accepted`.
#' For categorical rasters the categories are dropped in memory so that raw cell
#' codes are compared; the file is never modified.
#'
#' @param records `sf` points with `area_id`, `decimalLongitude`, `decimalLatitude`.
#' @param params Output of [validate_raster_filter()].
#' @return A list with `retained` (records plus a derived `raster_value` column,
#'   renamed with a `_derived` suffix on name collisions), `removed` (data frame:
#'   `area_id`, `reason`, `n_removed`) and `meta`.
#' @export
apply_raster_filter <- function(records, params) {
  r <- terra::rast(params$path)[[1]]
  if (isTRUE(terra::is.factor(r)[1])) levels(r) <- NULL
  n <- nrow(records)
  vals <- rep(NA_real_, n)
  in_extent <- logical(n)
  if (n > 0) {
    xy <- cbind(as.numeric(records$decimalLongitude), as.numeric(records$decimalLatitude))
    for (idx in split(seq_len(n), ceiling(seq_len(n) / .RASTER_CHUNK_SIZE))) {
      pts <- xy[idx, , drop = FALSE]
      in_extent[idx] <- !is.na(terra::cellFromXY(r, pts))
      v <- terra::extract(r, pts)[[1]]
      if (!is.numeric(v)) stop("Could not obtain numeric raster cell codes from ", params$path, call. = FALSE)
      vals[idx] <- as.numeric(v)
    }
  }
  reason <- rep(NA_character_, n)
  reason[!in_extent] <- "outside_raster_extent"
  reason[in_extent & is.na(vals)] <- "raster_nodata"
  reason[in_extent & !is.na(vals) & !(vals %in% params$accepted_values)] <- "raster_value_not_accepted"
  keep <- is.na(reason)

  retained <- records[keep, ]
  retained[[.safe_derived_name("raster_value", names(records))]] <- vals[keep]
  removed <- data.frame(area_id = character(), reason = character(), n_removed = integer(), stringsAsFactors = FALSE)
  if (any(!keep)) {
    tab <- as.data.frame(table(area_id = records$area_id[!keep], reason = reason[!keep]), stringsAsFactors = FALSE)
    tab <- tab[tab$Freq > 0, ]
    removed <- data.frame(area_id = tab$area_id, reason = tab$reason, n_removed = as.integer(tab$Freq), stringsAsFactors = FALSE)
  }
  lg_info("Raster filter: ", sum(keep), " of ", n, " records retained")
  list(retained = retained, removed = removed, meta = list(chunk_size = .RASTER_CHUNK_SIZE))
}

# Cache entries (read-only) -------------------------------------------------------

#' Load explicit GBIF cache entries without modifying them
#'
#' Validates each directory (both files present and readable, non-empty
#' `cache_key`/`area_id`, supported schema, key matching the directory name when
#' it follows the cache layout, row count matching `n_records`), rejects
#' duplicate keys or `area_id`s, and fingerprints both files (MD5) so that
#' immutability can be verified later. Only reads.
#'
#' @param entries Character vector of cache entry directories.
#' @return A list with `records` (named list by `area_id` of raw tables),
#'   `inputs` (data frame, one row per entry) and `meta` (named list by `area_id`).
#' @export
load_filter_inputs <- function(entries) {
  recs <- list(); metas <- list(); rows <- list()
  for (dir in entries) {
    fr <- file.path(dir, "records.rds"); fm <- file.path(dir, "meta.yaml")
    if (!dir.exists(dir)) stop("Cache entry directory not found: ", dir, call. = FALSE)
    for (f in c(fr, fm)) if (!file.exists(f)) stop("Cache entry ", dir, " is missing ", basename(f), call. = FALSE)
    meta <- tryCatch(yaml::read_yaml(fm), error = function(e) stop("Cannot read ", fm, ": ", conditionMessage(e), call. = FALSE))
    if (!is.list(meta)) stop("Malformed metadata (not a mapping): ", fm, call. = FALSE)
    key <- meta$cache_key
    if (!is.character(key) || length(key) != 1 || !nzchar(key)) stop("meta.yaml has no cache_key: ", fm, call. = FALSE)
    schema <- suppressWarnings(as.integer(meta$cache_schema))
    if (length(schema) != 1 || is.na(schema) || !schema %in% .SUPPORTED_CACHE_SCHEMAS) {
      stop("Unsupported cache_schema '", meta$cache_schema %||% "NULL", "' in ", fm, " (supported: ",
           paste(.SUPPORTED_CACHE_SCHEMAS, collapse = ", "), ")", call. = FALSE)
    }
    area <- meta$area_id
    if (!is.character(area) || length(area) != 1 || !nzchar(area)) stop("meta.yaml has no area_id: ", fm, call. = FALSE)
    if (grepl("^[0-9a-f]{32}$", basename(dir)) && !identical(basename(dir), key)) {
      stop("cache_key in ", fm, " (", key, ") does not match the directory name (", basename(dir), ")", call. = FALSE)
    }
    if (key %in% vapply(rows, `[[`, "", "cache_key")) stop("Duplicate cache key across entries: ", key, call. = FALSE)
    if (area %in% names(recs)) {
      stop("Duplicate area_id '", area, "' across cache entries; inputs with the same area_id cannot be told apart without merging them", call. = FALSE)
    }
    records <- tryCatch(readRDS(fr), error = function(e) stop("Cannot read ", fr, ": ", conditionMessage(e), call. = FALSE))
    if (!is.data.frame(records)) stop("records.rds is not a data frame: ", fr, call. = FALSE)
    if (!is.null(meta$n_records) && NROW(records) != meta$n_records) {
      stop("Row count mismatch in ", dir, ": records.rds has ", NROW(records), " rows, meta.yaml says ", meta$n_records, call. = FALSE)
    }
    f <- meta$filters
    fstr <- if (length(f)) paste0(names(f), "=", vapply(f, function(v) paste(unlist(v), collapse = ","), ""), collapse = "; ") else "(none)"
    recs[[area]] <- records; metas[[area]] <- meta
    rows[[length(rows) + 1]] <- data.frame(
      area_id = area, cache_key = key, cache_dir = normalizePath(dir, winslash = "/"),
      method = as.character(meta$method %||% "search"), queried_at = as.character(meta$queried_at %||% NA),
      n_records_meta = as.numeric(meta$n_records %||% NA), n_records_loaded = NROW(records),
      query_filters = fstr, download_doi = as.character(meta$download_doi %||% NA),
      records_md5 = unname(tools::md5sum(fr)), meta_md5 = unname(tools::md5sum(fm)),
      stringsAsFactors = FALSE)
    lg_info("Loaded cache entry for area '", area, "': ", NROW(records), " raw records (key ", key, ")")
  }
  list(records = recs, inputs = do.call(rbind, rows), meta = metas)
}

#' Verify that the input cache files still have the recorded MD5 fingerprints
#' @param inputs The `inputs` table from [load_filter_inputs()].
#' @return `TRUE` if unchanged; otherwise an error naming the changed files.
#' @export
verify_inputs_unchanged <- function(inputs) {
  now <- function(d, f) unname(tools::md5sum(file.path(d, f)))
  changed <- character()
  for (i in seq_len(nrow(inputs))) {
    if (!identical(now(inputs$cache_dir[i], "records.rds"), inputs$records_md5[i])) changed <- c(changed, file.path(inputs$cache_dir[i], "records.rds"))
    if (!identical(now(inputs$cache_dir[i], "meta.yaml"), inputs$meta_md5[i])) changed <- c(changed, file.path(inputs$cache_dir[i], "meta.yaml"))
  }
  if (length(changed)) stop("Input cache files changed during the run: ", paste(changed, collapse = ", "), call. = FALSE)
  TRUE
}

#' Rebuild the area polygon from `geometry_wkt` in the cache metadata
#'
#' @param area_id Area identifier.
#' @param wkt WKT string (EPSG:4326) or `NULL`.
#' @return A one-row `sf` object (`area_id`), or `NULL` if the WKT is absent or invalid.
#' @export
area_from_wkt <- function(area_id, wkt) {
  if (!is.character(wkt) || length(wkt) != 1 || !nzchar(wkt)) return(NULL)
  g <- tryCatch(sf::st_as_sfc(wkt, crs = 4326), error = function(e) NULL)
  if (is.null(g) || length(g) != 1 || !inherits(g[[1]], c("POLYGON", "MULTIPOLYGON")) ||
      sf::st_is_empty(g) || !isTRUE(sf::st_is_valid(g))) return(NULL)
  sf::st_sf(area_id = area_id, geometry = g)
}

# Profiles ------------------------------------------------------------------------

.with_stage <- function(stage, df) data.frame(stage = rep(stage, nrow(df)), df, stringsAsFactors = FALSE)

.counts_by_area <- function(ids, area_ids) as.integer(table(factor(ids, levels = area_ids)))

#' Descriptive profile of a set of records, per area
#'
#' The same definitions are used for the raw, pre-filter and post-filter
#' profiles: record counts, distinct species/genera/families (observed taxa,
#' not true richness), temporal coverage and, when area geometry and point
#' records are available, spatial coverage from the density grid. Spatial
#' columns are `NA` when not computed.
#'
#' @param records A data frame or `sf` object with `area_id`.
#' @param area_ids Area identifiers (areas without records get zeros).
#' @param top_n Number of top classes per area.
#' @param areas Optional `sf` areas with `area_km2`.
#' @param metric_crs Projected CRS for the density grid (with `areas`).
#' @param cell_km Density grid cell side in km (with `areas`).
#' @return A list with `summary` (one row per area), `by_year`, `top_classes`
#'   and `density` (`sf` or `NULL`).
#' @export
calculate_profile <- function(records, area_ids, top_n = 10L, areas = NULL, metric_crs = NULL, cell_km = NULL) {
  df <- if (inherits(records, "sf")) sf::st_drop_geometry(records) else as.data.frame(records)
  if (!"area_id" %in% names(df)) df$area_id <- character(nrow(df))
  df$area_id <- as.character(df$area_id)
  for (cl in c("species", "genus", "family", "class")) if (!cl %in% names(df)) df[[cl]] <- rep(NA_character_, nrow(df))
  df$year <- if ("year" %in% names(df)) suppressWarnings(as.numeric(df$year)) else rep(NA_real_, nrow(df))

  tax <- calculate_taxonomic_metrics(df, area_ids, top_n)
  tmp <- calculate_temporal_metrics(df, area_ids)
  out <- data.frame(area_id = area_ids, n_records = .counts_by_area(df$area_id, area_ids), stringsAsFactors = FALSE)
  out <- merge(out, tax$summary, by = "area_id", sort = FALSE)
  out <- merge(out, tmp$summary, by = "area_id", sort = FALSE)
  out[c("area_km2", "records_per_km2", "n_cells", "n_cells_with_records", "coverage_pct",
        "top10pct_cells_share_pct")] <- NA_real_
  dens <- NULL
  if (!is.null(areas) && inherits(records, "sf")) {
    a <- areas[areas$area_id %in% area_ids, ]
    if (nrow(a) > 0) {
      d <- calculate_density(records[records$area_id %in% a$area_id, ], a, metric_crs, cell_km)
      dens <- d$density
      m <- match(out$area_id, d$summary$area_id)
      for (cl in c("n_cells", "n_cells_with_records", "coverage_pct", "top10pct_cells_share_pct")) out[[cl]] <- d$summary[[cl]][m]
      out$area_km2 <- a$area_km2[match(out$area_id, a$area_id)]
      out$records_per_km2 <- out$n_records / out$area_km2
    }
  }
  out <- out[match(area_ids, out$area_id), ]
  rownames(out) <- NULL
  list(summary = out, by_year = tmp$by_year, top_classes = tax$top_classes, density = dens)
}

#' Long-format comparison of the raw, pre-filter and post-filter profiles
#' @param profiles Named list with `raw`, `pre_filter`, `post_filter` profiles.
#' @return A data frame (`area_id`, `metric`, `raw`, `pre_filter`, `post_filter`).
#' @export
profile_comparison_table <- function(profiles) {
  metrics <- setdiff(names(profiles$raw$summary), "area_id")
  rows <- lapply(metrics, function(m) {
    data.frame(area_id = profiles$raw$summary$area_id, metric = m,
               raw = profiles$raw$summary[[m]], pre_filter = profiles$pre_filter$summary[[m]],
               post_filter = profiles$post_filter$summary[[m]], stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

#' Compare observed counts across the three profiles
#' @param profiles Named list with `raw`, `pre_filter`, `post_filter` profiles.
#' @return A ggplot.
#' @export
plot_profile_comparison <- function(profiles) {
  metrics <- c("n_records", "n_species", "n_genera", "n_families")
  long <- do.call(rbind, lapply(names(profiles), function(st) {
    cbind(stage = st, profiles[[st]]$summary[, c("area_id", metrics)], stringsAsFactors = FALSE)
  }))
  long <- tidyr::pivot_longer(long, dplyr::all_of(metrics), names_to = "metric", values_to = "value")
  long$stage <- factor(long$stage, c("raw", "pre_filter", "post_filter"),
                       c("Raw (cache)", "Pre-filter (technically valid)", "Post-filter"))
  long$metric <- factor(long$metric, metrics, c("Records", "Distinct species", "Distinct genera", "Distinct families"))
  ggplot2::ggplot(long, ggplot2::aes(.data$area_id, .data$value, fill = .data$stage)) +
    ggplot2::geom_col(position = "dodge") +
    ggplot2::facet_wrap(~metric, scales = "free_y") +
    ggplot2::labs(x = NULL, y = NULL, fill = NULL, title = "Observed counts before and after filtering") + .theme() +
    ggplot2::theme(legend.position = "bottom")
}

#' Records per year before and after filtering
#' @param profiles Named list with `pre_filter` and `post_filter` profiles.
#' @return A ggplot, or `NULL` when there are no records with a year.
#' @export
plot_year_comparison <- function(profiles) {
  d <- rbind(.with_stage("Pre-filter", profiles$pre_filter$by_year),
             .with_stage("Post-filter", profiles$post_filter$by_year))
  if (nrow(d) == 0) return(NULL)
  d$stage <- factor(d$stage, c("Pre-filter", "Post-filter"))
  ggplot2::ggplot(d, ggplot2::aes(.data$year, .data$n_records, colour = .data$stage)) +
    ggplot2::geom_line() + ggplot2::geom_point(size = 1) +
    ggplot2::facet_wrap(~area_id, scales = "free_y") +
    ggplot2::labs(x = "Year", y = "Records", colour = NULL, title = "Records per year") + .theme() +
    ggplot2::theme(legend.position = "bottom")
}

# Filtering stages ------------------------------------------------------------------

#' Run the enabled filters sequentially with stage accounting
#'
#' For every stage the denominator is the set of records passed into it (after
#' previous stages), so per-stage removals must not be summed as if unique.
#'
#' @param records `sf` records (technically valid, with `area_id`).
#' @param enabled List of `list(spec, params)` from the validated configuration.
#' @param area_ids Area identifiers (zero counts are kept).
#' @return A list with `records`, `removed`, `stages` and `applied` (metadata).
#' @export
apply_filters <- function(records, enabled, area_ids) {
  cur <- records
  removed <- list(); stages <- list(); applied <- list()
  for (i in seq_along(enabled)) {
    spec <- enabled[[i]]$spec; params <- enabled[[i]]$params
    lg_info("Applying filter ", spec$id, " (", spec$category, ") to ", nrow(cur), " records")
    t0 <- Sys.time()
    res <- spec$apply(cur, params)
    n_in <- .counts_by_area(cur$area_id, area_ids)
    n_out <- .counts_by_area(res$retained$area_id, area_ids)
    rem <- res$removed
    n_rem_tab <- if (nrow(rem)) tapply(rem$n_removed, factor(rem$area_id, levels = area_ids), sum) else rep(NA, length(area_ids))
    n_rem_tab[is.na(n_rem_tab)] <- 0
    if (!identical(as.integer(n_in - n_out), as.integer(n_rem_tab))) {
      stop("Internal accounting error in filter ", spec$id, ": removed counts do not match input minus retained", call. = FALSE)
    }
    stages[[i]] <- data.frame(area_id = area_ids, stage_order = i + 1L, stage_type = "filter", filter_id = spec$id,
                              category = spec$category, n_input = n_in, n_retained = n_out, n_removed = n_in - n_out,
                              stringsAsFactors = FALSE)
    if (nrow(rem)) removed[[i]] <- data.frame(area_id = rem$area_id, stage_type = "filter", filter_id = spec$id,
                                              reason = rem$reason, n_removed = rem$n_removed, stringsAsFactors = FALSE)
    applied[[i]] <- list(id = spec$id, category = spec$category, parameters = spec$describe(params),
                         n_input = sum(n_in), n_retained = sum(n_out),
                         duration_seconds = round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2))
    cur <- res$retained
  }
  list(records = cur, removed = do.call(rbind, Filter(Negate(is.null), removed)),
       stages = do.call(rbind, stages), applied = applied)
}

#' Objective limitations for the filtering report
#' @param ctx Filtering run context.
#' @return A character vector.
#' @export
build_filtering_limitations <- function(ctx) {
  out <- character()
  for (a in ctx$applied) {
    out <- c(out, paste0("Filter ", a$id, " (", a$category, "): ", a$n_retained, " of ", a$n_input,
                         " records passed into it were retained."))
  }
  out <- c(out,
    "Stage removals are counted against the records passed into each stage; per-stage removals are not necessarily unique across criteria.",
    "The raster filter uses exact matching of raw cell codes (not category labels, ranges or thresholds); the raster is not reprojected, resampled or validated ecologically.",
    "The raster must be EPSG:4326 (WGS 84 lon/lat); occurrence coordinates are used as stored in GBIF.",
    "Counts describe the availability of GBIF records and the effect of the configured filters; distinct taxa are observed names, not true richness, and no bias correction or inference was performed.")
  after <- ctx$profiles$post_filter$summary
  low <- after$area_id[!is.na(after$coverage_pct) & after$n_records > 0 & after$coverage_pct < ctx$config$analysis$low_coverage_pct]
  if (length(low)) out <- c(out, paste0("Low spatial coverage after filtering (< ", ctx$config$analysis$low_coverage_pct, "% of cells with records) in: ", paste(low, collapse = ", "), "."))
  none <- after$area_id[after$n_records == 0]
  if (length(none)) out <- c(out, paste0("No records remain after filtering in: ", paste(none, collapse = ", "), "."))
  nogeom <- ctx$areas$area_id[!ctx$areas$geometry_available]
  if (length(nogeom)) out <- c(out, paste0("Area geometry unavailable or invalid in cache metadata (spatial metrics and maps skipped): ", paste(nogeom, collapse = ", "), "."))
  c(out,
    "Spatial metrics are not computed for the raw profile (coordinates are not yet validated at that stage).",
    "The raster is identified by path and MD5 of the main file; multi-file raster formats are only partially covered by the fingerprint.")
}

# Orchestrator -----------------------------------------------------------------------

#' Run the independent filtering workflow
#'
#' Entry point of `scripts/filter.R`. Reads only explicit cache entries, never
#' calls GBIF, never writes inside the cache, and writes everything under a new
#' run directory. Errors are logged and turned into a non-zero status.
#'
#' @param config_path Absolute path to the filtering YAML configuration.
#' @param root Project root directory.
#' @return `0L` on success, `1L` on failure.
#' @export
run_filtering <- function(config_path, root) {
  collector <- setup_logging("INFO")
  state <- new.env(parent = emptyenv())
  ok <- tryCatch({
    withCallingHandlers(
      .run_filtering_pipeline(config_path, root, collector, state),
      warning = function(w) {
        lg_warn("R warning: ", conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
    TRUE
  }, error = function(e) {
    lg_error(conditionMessage(e))
    lg_error("Filtering aborted; no final report was produced.")
    if (!is.null(state$run_dir)) {
      unchanged <- if (is.null(state$inputs)) NA else tryCatch(verify_inputs_unchanged(state$inputs), error = function(e2) FALSE)
      try(yaml::write_yaml(list(status = "failed", error = conditionMessage(e), inputs_unchanged = unchanged,
                                finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
                           file.path(state$run_dir, "run_status.yaml")), silent = TRUE)
    }
    FALSE
  })
  if (ok) 0L else 1L
}

.run_filtering_pipeline <- function(config_path, root, collector, state) {
  started <- Sys.time()
  timings <- new.env(parent = emptyenv())
  lg_info("Starting GBIF occurrence filtering (no GBIF access; cache is read-only)")

  raw_cfg <- run_step("read configuration", read_config(config_path), timings)
  cfg <- run_step("validate configuration", validate_filter_config(raw_cfg, root), timings)
  set_log_level(cfg$logging$level)

  run_id <- format(started, "%Y%m%d_%H%M%S")
  run_dir <- file.path(cfg$paths$output, paste0("run_", run_id))
  if (dir.exists(run_dir)) stop("Run directory already exists: ", run_dir, call. = FALSE)
  for (d in c("figures", "spatial", "tables", "logs", "report")) ensure_dir(file.path(run_dir, d))
  state$run_dir <- run_dir
  add_log_file(file.path(run_dir, "logs", paste0("run_", run_id, ".log")))
  file.copy(config_path, file.path(run_dir, "config_original.yaml"))
  cfg_eff <- cfg[setdiff(names(cfg), c("filters_enabled", "paths"))]
  cfg_eff$filters_effective <- lapply(cfg$filters_enabled, function(e) list(id = e$spec$id, category = e$spec$category, params = e$params))
  yaml::write_yaml(cfg_eff, file.path(run_dir, "config_effective.yaml"))
  lg_info("Run directory: ", run_dir)
  lg_info("Effective configuration:\n", yaml::as.yaml(cfg_eff))

  tool_version <- get_tool_version(root)
  env <- environment_info(root)
  git <- git_info(root)
  if (!git$available) lg_warn("Git information unavailable")
  if (!env$renv_active) lg_warn("renv is not active for this project; the run may not be reproducible")

  # inputs --------------------------------------------------------------------------
  loaded <- run_step("load cache entries", load_filter_inputs(cfg$paths$cache_entries), timings)
  state$inputs <- loaded$inputs
  area_ids <- loaded$inputs$area_id
  top_n <- cfg$analysis$top_n; cell_km <- cfg$analysis$density_cell_km

  areas <- NULL; metric_crs <- NULL
  parts <- lapply(area_ids, function(id) {
    a <- area_from_wkt(id, loaded$meta[[id]]$geometry_wkt)
    if (is.null(a)) lg_warn("geometry_wkt missing or invalid for area '", id, "'; spatial summaries and maps are skipped for it")
    a
  })
  loaded$inputs$geometry_available <- !vapply(parts, is.null, logical(1))
  parts <- Filter(Negate(is.null), parts)
  if (length(parts)) {
    areas <- do.call(rbind, parts)
    metric_crs <- get_metric_crs(areas, cfg$analysis$metric_crs)
    areas$area_km2 <- area_km2(areas, metric_crs)
  }

  # profiles and filtering -------------------------------------------------------------
  raw <- combine_area_records(loaded$records)
  lg_info("Raw input records: ", nrow(raw))
  prof_raw <- run_step("raw profile", calculate_profile(raw, area_ids, top_n), timings)

  v <- run_step("technical validation", validate_records(raw), timings)
  valid <- records_to_sf(v$records)
  lg_info("Records after technical validation: ", nrow(valid))
  prof_before <- run_step("pre-filter profile", calculate_profile(valid, area_ids, top_n, areas, metric_crs, cell_km), timings)

  fr <- run_step("apply filters", apply_filters(valid, cfg$filters_enabled, area_ids), timings)
  lg_info("Records after all filters: ", nrow(fr$records))
  if (nrow(fr$records) == 0) lg_warn("No records remain after filtering; empty tables and report will be produced")
  prof_after <- run_step("post-filter profile", calculate_profile(fr$records, area_ids, top_n, areas, metric_crs, cell_km), timings)
  profiles <- list(raw = prof_raw, pre_filter = prof_before, post_filter = prof_after)

  # accounting tables ----------------------------------------------------------------------
  n_raw <- .counts_by_area(raw$area_id, area_ids); n_valid <- .counts_by_area(valid$area_id, area_ids)
  stages <- rbind(
    data.frame(area_id = area_ids, stage_order = 1L, stage_type = "validation", filter_id = "technical_validation",
               category = "technical", n_input = n_raw, n_retained = n_valid, n_removed = n_raw - n_valid, stringsAsFactors = FALSE),
    fr$stages)
  removed <- rbind(
    if (nrow(v$removed)) data.frame(area_id = v$removed$area_id, stage_type = "validation", filter_id = "technical_validation",
                                    reason = v$removed$reason, n_removed = v$removed$n_removed %||% v$removed$n, stringsAsFactors = FALSE),
    fr$removed)
  if (is.null(removed)) removed <- data.frame(area_id = character(), stage_type = character(), filter_id = character(),
                                              reason = character(), n_removed = integer(), stringsAsFactors = FALSE)
  by_year <- rbind(.with_stage("pre_filter", prof_before$by_year), .with_stage("post_filter", prof_after$by_year))
  tables <- list(
    input_entries = loaded$inputs[, setdiff(names(loaded$inputs), "geometry_available")],
    profile_raw = prof_raw$summary, profile_before_filter = prof_before$summary, profile_after_filter = prof_after$summary,
    profile_by_year = by_year, profile_comparison = profile_comparison_table(profiles),
    filter_summary = stages, removed_records = removed)
  run_step("write tables", write_output_tables(tables, file.path(run_dir, "tables")), timings)

  run_step("write spatial output", {
    layers <- list(gbif_filtered_records = .gpkg_safe(fr$records))
    if (!is.null(areas)) layers$areas <- areas
    write_spatial_layers(layers, file.path(run_dir, "spatial", "gbif_filtered_records.gpkg"))
  }, timings)

  figs <- run_step("create figures", {
    fd <- file.path(run_dir, "figures"); f <- list()
    f$profile_comparison <- save_plot(plot_profile_comparison(profiles), file.path(fd, "profile_comparison.png"), width = 9, height = 6)
    f$year_comparison <- save_plot(plot_year_comparison(profiles), file.path(fd, "year_comparison.png"), width = 9, height = 5)
    if (!is.null(areas)) {
      nm <- .safe_name(areas$area_id)
      mk <- function(plots, prefix) stats::setNames(lapply(seq_along(plots), function(i)
        save_plot(plots[[i]], file.path(fd, paste0(prefix, "_", nm[i], ".png")))), areas$area_id)
      mp <- cfg$analysis$max_map_points
      f$records_before <- mk(plot_records(areas, valid, mp, "Pre-filter records"), "map_records_pre_filter")
      f$records_after <- mk(plot_records(areas, fr$records, mp, "Post-filter records"), "map_records_post_filter")
      f$density_before <- mk(plot_density(prof_before$density, areas, "Pre-filter density"), "map_density_pre_filter")
      f$density_after <- mk(plot_density(prof_after$density, areas, "Post-filter density"), "map_density_post_filter")
    }
    f
  }, timings)

  # report ------------------------------------------------------------------------------------
  filters_applied <- do.call(rbind, lapply(fr$applied, function(a) cbind(category = a$category, filter_id = a$id, a$parameters)))
  ctx <- list(
    project = cfg$project$name, run_id = run_id, run_dir = run_dir, config_path = config_path,
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"), tool_version = tool_version, git = git, environment = env,
    config = cfg_eff, config_effective = cfg_eff, inputs = loaded$inputs, applied = fr$applied,
    filters_applied = filters_applied,
    raster = lapply(cfg$filters_enabled, function(e) e$params)[["spatial.raster"]],
    areas = data.frame(area_id = area_ids, geometry_available = loaded$inputs$geometry_available,
                       area_km2 = if (is.null(areas)) NA_real_ else areas$area_km2[match(area_ids, areas$area_id)], stringsAsFactors = FALSE),
    stages = stages, removed = removed, profiles = lapply(profiles, function(p) p[c("summary", "by_year")]),
    comparison = tables$profile_comparison, figures = figs, warnings = collector$store$msgs,
    timings = as.list(timings))
  ctx$limitations <- build_filtering_limitations(ctx)
  ctx_file <- file.path(run_dir, "tables", "run_context.rds")
  saveRDS(ctx, ctx_file)
  run_step("render PDF report", render_report(ctx_file, file.path(root, "report", "filtering_report_template.Rmd"),
                                              file.path(run_dir, "report", "filtering_report.pdf")), timings)

  unchanged <- verify_inputs_unchanged(loaded$inputs)
  dur <- round(as.numeric(difftime(Sys.time(), started, units = "secs")), 1)
  yaml::write_yaml(list(status = "completed", run_id = run_id, duration_seconds = dur, inputs_unchanged = unchanged,
                        n_raw = nrow(raw), n_pre_filter = nrow(valid), n_retained = nrow(fr$records),
                        finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
                   file.path(run_dir, "run_status.yaml"))
  lg_info("Filtering completed successfully (", dur, " s). Results: ", run_dir)
  invisible(TRUE)
}
