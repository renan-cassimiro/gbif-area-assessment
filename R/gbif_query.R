# GBIF query -------------------------------------------------------------------

.CACHE_SCHEMA_VERSION <- 1L

# Orient polygon rings as required by GBIF (exterior CCW, holes CW).
.ring_area <- function(m) {
  n <- nrow(m)
  sum(m[-n, 1] * m[-1, 2] - m[-1, 1] * m[-n, 2]) / 2
}

.orient_polygon <- function(p) {
  p <- lapply(seq_along(p), function(i) {
    m <- p[[i]]
    a <- .ring_area(m)
    if ((i == 1 && a < 0) || (i > 1 && a > 0)) m <- m[nrow(m):1, , drop = FALSE]
    m
  })
  p
}

#' Convert an area geometry to a GBIF-compatible WKT string
#'
#' Rings are re-oriented (exterior counter-clockwise, holes clockwise) and
#' coordinates are rounded to 6 decimals; no simplification is performed.
#'
#' @param geometry An `sfc` of length 1 (POLYGON or MULTIPOLYGON) in EPSG:4326.
#' @return A WKT string.
#' @export
area_to_wkt <- function(geometry) {
  g <- sf::st_geometry(geometry)[[1]]
  crs <- sf::st_crs(geometry)
  if (is.na(crs) || crs != sf::st_crs(4326)) stop("Area geometry must be in EPSG:4326.", call. = FALSE)
  if (inherits(g, "POLYGON")) {
    g <- sf::st_polygon(.orient_polygon(unclass(g)))
  } else if (inherits(g, "MULTIPOLYGON")) {
    g <- sf::st_multipolygon(lapply(unclass(g), .orient_polygon))
  } else stop("Unsupported geometry type for GBIF query.", call. = FALSE)
  sf::st_as_text(g, digits = 6)
}

#' Build the GBIF query description for one area
#'
#' Translates the normalised configuration into the arguments used by
#' [rgbif::occ_data()].
#'
#' @param area_id Area identifier.
#' @param geometry `sfc` of length 1 (EPSG:4326).
#' @param filters Normalised filters from [normalize_gbif_filters()].
#' @param query_cfg The `gbif$query` configuration section.
#' @return A list describing the query (`area_id`, `geometry`, `filters`,
#'   `filter_sets`, `null_overrides`, limits).
#' @export
build_gbif_query <- function(area_id, geometry, filters, query_cfg) {
  wkt <- area_to_wkt(geometry)
  if (nchar(wkt) > query_cfg$max_wkt_chars) {
    stop("Geometry of area '", area_id, "' has a WKT of ", nchar(wkt), " characters (limit ",
         query_cfg$max_wkt_chars, "; gbif.query.max_wkt_chars). Provide a simpler polygon: ",
         "the tool never simplifies geometries silently.", call. = FALSE)
  }
  list(
    area_id = area_id,
    geometry = wkt,
    filters = filters,
    filter_sets = expand_filter_sets(filters, query_cfg$max_filter_combinations),
    null_overrides = rgbif_default_overrides(names(filters)),
    max_records = query_cfg$max_records,
    page_size = query_cfg$page_size,
    max_retries = query_cfg$max_retries,
    retry_wait_seconds = query_cfg$retry_wait_seconds
  )
}

.with_retry <- function(fn, max_retries, wait, what) {
  attempt <- 0
  repeat {
    attempt <- attempt + 1
    res <- tryCatch(fn(), error = function(e) e)
    if (!inherits(res, "error")) return(res)
    if (attempt > max_retries) {
      stop("GBIF request failed after ", attempt, " attempt(s) (", what, "): ", conditionMessage(res), call. = FALSE)
    }
    lg_warn("GBIF request failed (", what, "), attempt ", attempt, "/", max_retries + 1,
            ": ", conditionMessage(res), ". Retrying in ", wait * attempt, " s")
    Sys.sleep(wait * attempt)
  }
}

# Make column types consistent across data frames before binding.
.harmonize_types <- function(dfs) {
  dfs <- Filter(function(d) !is.null(d) && ncol(d) > 0, dfs)
  cols <- unique(unlist(lapply(dfs, names)))
  conv <- list(double = as.numeric, integer = as.integer, character = as.character, logical = as.logical)
  for (col in cols) {
    info <- lapply(dfs, function(d) if (col %in% names(d)) list(type = typeof(d[[col]]), allna = all(is.na(d[[col]]))))
    info <- Filter(Negate(is.null), info)
    types <- unique(vapply(info, `[[`, "", "type"))
    if (length(types) <= 1 || "list" %in% types) next
    informative <- unique(vapply(Filter(function(i) !i$allna, info), `[[`, "", "type"))
    target <- if (length(informative) == 1) informative else "character"
    f <- conv[[target]] %||% as.character
    for (k in seq_along(dfs)) if (col %in% names(dfs[[k]])) dfs[[k]][[col]] <- f(dfs[[k]][[col]])
    lg_debug("Column '", col, "' coerced to ", target, " to combine results")
  }
  dfs
}

#' Bind data frames with differing column types safely
#' @param dfs List of data frames.
#' @return A single data frame (tibble).
#' @keywords internal
bind_records <- function(dfs) {
  dfs <- .harmonize_types(dfs)
  if (length(dfs) == 0) return(dplyr::tibble())
  dplyr::bind_rows(dfs)
}

.query_one <- function(query, set, label) {
  base <- c(list(geometry = query$geometry), set, query$null_overrides)
  fetch <- function(start, limit) {
    .with_retry(function() do.call(rgbif::occ_data, c(base, list(limit = limit, start = start))),
                query$max_retries, query$retry_wait_seconds, paste0(label, ", offset ", start))
  }
  first <- fetch(0, query$page_size)
  count <- first$meta$count %||% 0
  lg_info("Request ", label, ": GBIF reports ", count, " record(s)")
  if (count > query$max_records) {
    stop("Request ", label, " matches ", count, " records, above gbif.query.max_records (",
         query$max_records, "). The search API cannot page beyond 100,000 records: split the study area ",
         "or add filters (bulk downloads via occ_download are out of scope in this version).", call. = FALSE)
  }
  if (count == 0 || is.null(first$data) || NROW(first$data) == 0) {
    return(list(data = dplyr::tibble(), count = 0, pages = 1L))
  }
  pages <- list(first$data)
  offset <- NROW(first$data)
  while (offset < count) {
    res <- fetch(offset, query$page_size)
    d <- res$data
    if (is.null(d) || NROW(d) == 0) break
    pages[[length(pages) + 1]] <- d
    offset <- offset + NROW(d)
    lg_debug("Request ", label, ": page ", length(pages), ", ", offset, "/", count, " records")
    if (length(pages) %% 20 == 0) lg_info("Request ", label, ": ", offset, "/", count, " records retrieved")
    if (isTRUE(res$meta$endOfRecords)) break
  }
  if (offset < count) {
    stop("Request ", label, " ended early (", offset, " of ", count, " records retrieved); data would be incomplete.", call. = FALSE)
  }
  list(data = bind_records(pages), count = count, pages = length(pages))
}

.count_unfiltered <- function(query) {
  res <- tryCatch(
    .with_retry(function() do.call(rgbif::occ_data, c(list(geometry = query$geometry), query$null_overrides,
                                                      list(limit = 1, start = 0))),
                query$max_retries, query$retry_wait_seconds, "unfiltered count"),
    error = function(e) { lg_warn(conditionMessage(e)); NULL })
  if (is.null(res)) NA_real_ else (res$meta$count %||% 0)
}

#' Query GBIF occurrence records
#'
#' Runs the paginated spatial query (one request per filter combination),
#' merges and de-duplicates by `gbifID`, and returns the raw records and
#' metadata. Raises an error on API failure or incomplete retrieval.
#'
#' @param query List from [build_gbif_query()].
#' @return A list with `records` (raw tibble) and `meta` (query metadata).
#' @export
query_gbif <- function(query) {
  lg_info("Querying GBIF for area '", query$area_id, "' (", length(query$filter_sets), " request(s))")
  t0 <- Sys.time()
  parts <- vector("list", length(query$filter_sets))
  pages <- 0L; counts <- numeric()
  for (i in seq_along(query$filter_sets)) {
    label <- sprintf("%s [%d/%d]", query$area_id, i, length(query$filter_sets))
    r <- .query_one(query, query$filter_sets[[i]], label)
    parts[[i]] <- r$data; pages <- pages + r$pages; counts <- c(counts, r$count)
  }
  records <- bind_records(parts)
  n_raw <- NROW(records)
  if (n_raw > 0 && "gbifID" %in% names(records)) {
    records <- records[!duplicated(records$gbifID), ]
    if (NROW(records) < n_raw) lg_info("Removed ", n_raw - NROW(records), " duplicate record(s) across filter combinations")
  }
  total <- .count_unfiltered(query)
  if (NROW(records) == 0) lg_warn("GBIF returned no records for area '", query$area_id, "'")
  lg_info("Records retrieved for area '", query$area_id, "': ", NROW(records), " (", pages, " page(s), ",
          round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), " s)")
  list(
    records = records,
    meta = list(
      queried_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
      n_records = NROW(records),
      n_total_without_filters = total,
      n_pages = pages,
      gbif_counts_by_request = counts,
      rgbif_version = as.character(utils::packageVersion("rgbif"))
    )
  )
}

#' Get records for one area from the cache or from the GBIF API
#'
#' Cache behaviour: the cache is read only when `enabled`, `use_cached` and not
#' `refresh`; it is written whenever `enabled` (previous versions are archived,
#' never overwritten silently).
#'
#' @param query List from [build_gbif_query()].
#' @param cache_cfg The `gbif$cache` section with `directory` resolved.
#' @param cache_dir Absolute cache directory.
#' @param tool_version Tool version recorded in the cache metadata.
#' @return A list with `records`, `meta`, `source` (`"cache"`/`"api"`) and `cache_key`.
#' @export
get_gbif_records <- function(query, cache_cfg, cache_dir, tool_version) {
  key <- build_cache_key(query)
  lg_info("Cache key (area '", query$area_id, "'): ", key)
  found <- cache_cfg$enabled && !is.null(find_cached_query(cache_dir, key))
  read_cache <- cache_cfg$enabled && cache_cfg$use_cached && !cache_cfg$refresh
  if (read_cache && found) {
    lg_info("Cached query found; loading cached occurrence records")
    loaded <- load_gbif_cache(cache_dir, key)
    lg_info("Records loaded from cache: ", NROW(loaded$records))
    return(list(records = loaded$records, meta = loaded$meta, source = "cache", cache_key = key))
  }
  if (!cache_cfg$enabled) lg_info("Cache disabled; querying the GBIF API")
  else if (cache_cfg$refresh) lg_info("Cache refresh requested; querying the GBIF API")
  else if (!cache_cfg$use_cached) lg_info("use_cached = false; querying the GBIF API")
  else lg_info("No cached query found; querying the GBIF API")
  res <- query_gbif(query)
  meta <- c(list(cache_key = key, area_id = query$area_id, tool_version = tool_version,
                 cache_schema = .CACHE_SCHEMA_VERSION, geometry_wkt = query$geometry,
                 filters = query$filters, rgbif_default_overrides = names(query$null_overrides)),
            res$meta)
  if (cache_cfg$enabled) save_gbif_cache(cache_dir, key, res$records, meta)
  list(records = res$records, meta = meta, source = "api", cache_key = key)
}
