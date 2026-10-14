# Local cache of raw GBIF responses --------------------------------------------

.sort_filters <- function(filters) {
  if (length(filters) == 0) return(list())
  filters <- filters[order(names(filters))]
  lapply(filters, function(v) if (length(v) > 1) sort(unique(v)) else v)
}

#' Build the deterministic cache key of a query
#'
#' The key hashes the geometry (WKT, 6 decimals), the normalised filters, the
#' rgbif defaults that were overridden, the API identifier and the cache schema
#' version. File names play no role.
#'
#' @param query List from [build_gbif_query()].
#' @return A 32-character hash string.
#' @export
build_cache_key <- function(query) {
  canon <- list(
    schema = .CACHE_SCHEMA_VERSION,
    api = "gbif-occurrence-search-v1",
    geometry = query$geometry,
    filters = .sort_filters(query$filters),
    null_overrides = sort(names(query$null_overrides))
  )
  if (identical(query$method, "download")) canon$method <- "download"
  rlang::hash(yaml::as.yaml(canon))
}

.cache_paths <- function(cache_dir, key) {
  d <- file.path(cache_dir, key)
  list(dir = d, records = file.path(d, "records.rds"), meta = file.path(d, "meta.yaml"))
}

#' Find a cached query
#' @param cache_dir Cache root directory.
#' @param key Cache key.
#' @return The cache entry directory, or `NULL`.
#' @export
find_cached_query <- function(cache_dir, key) {
  p <- .cache_paths(cache_dir, key)
  if (file.exists(p$records) && file.exists(p$meta)) p$dir else NULL
}

#' Save raw GBIF records and metadata to the cache
#'
#' An existing entry with the same key is moved to `archive/<timestamp>/`
#' before the new one is written.
#'
#' @param cache_dir Cache root directory.
#' @param key Cache key.
#' @param records Raw records (data frame).
#' @param meta Metadata list (must include `cache_key`, `n_records`, ...).
#' @return The entry directory, invisibly.
#' @export
save_gbif_cache <- function(cache_dir, key, records, meta) {
  p <- .cache_paths(cache_dir, key)
  ensure_dir(p$dir)
  if (file.exists(p$records) || file.exists(p$meta)) {
    arch <- file.path(p$dir, "archive", format(Sys.time(), "%Y%m%d_%H%M%S", tz = "UTC"))
    ensure_dir(arch)
    for (f in c(p$records, p$meta)) if (file.exists(f)) file.rename(f, file.path(arch, basename(f)))
    lg_info("Previous cache version archived at: ", arch)
  }
  tmp <- tempfile(tmpdir = p$dir, fileext = ".rds")
  saveRDS(records, tmp)
  file.rename(tmp, p$records)
  yaml::write_yaml(meta, p$meta)
  lg_info("Raw GBIF response cached (", NROW(records), " records): ", p$dir)
  invisible(p$dir)
}

#' Load cached GBIF records
#'
#' Verifies that the stored metadata matches the requested key and record
#' count; an inconsistent entry is an error (never reused silently).
#'
#' @param cache_dir Cache root directory.
#' @param key Cache key.
#' @return A list with `records` and `meta`.
#' @export
load_gbif_cache <- function(cache_dir, key) {
  p <- .cache_paths(cache_dir, key)
  meta <- yaml::read_yaml(p$meta)
  if (!identical(meta$cache_key, key) || !identical(as.integer(meta$cache_schema), .CACHE_SCHEMA_VERSION)) {
    stop("Cache entry ", p$dir, " does not match the current query (key/schema mismatch). ",
         "Set gbif.cache.refresh: true to rebuild it.", call. = FALSE)
  }
  records <- readRDS(p$records)
  if (NROW(records) != meta$n_records) {
    stop("Cache entry ", p$dir, " is inconsistent (", NROW(records), " records vs ", meta$n_records,
         " in metadata). Set gbif.cache.refresh: true to rebuild it.", call. = FALSE)
  }
  list(records = records, meta = meta)
}
