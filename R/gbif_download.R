# GBIF asynchronous occurrence download (occ_download) -------------------------

.DOWNLOAD_FORMAT <- "SIMPLE_CSV"
.DOWNLOAD_FAILED <- c("CANCELLED", "KILLED", "FAILED", "FILE_ERASED")

#' Check that all filters can be expressed as download predicates
#'
#' In this version only the typed filters of the registry (see
#' [gbif_filter_registry()]) are supported by the download method.
#'
#' @param filters Normalised filters from [normalize_gbif_filters()].
#' @return `TRUE`, invisibly; errors otherwise.
#' @export
check_download_filters <- function(filters) {
  bad <- setdiff(names(filters), names(gbif_filter_registry()))
  if (length(bad)) {
    abort_config("filter(s) not supported with gbif.query.method = \"download\" in this version: ",
                 paste(bad, collapse = ", "), ". Supported: ",
                 paste(names(gbif_filter_registry()), collapse = ", "))
  }
  invisible(TRUE)
}

.range_predicates <- function(nm, v, kind) {
  conv <- if (kind == "date") identity else as.numeric
  if (!grepl(",", v, fixed = TRUE)) return(list(rgbif::pred(nm, conv(v))))
  p <- strsplit(v, ",", fixed = TRUE)[[1]]
  list(rgbif::pred_gte(nm, conv(p[1])), rgbif::pred_lte(nm, conv(p[2])))
}

#' Translate the area and filters into GBIF download predicates
#'
#' All predicates are combined with AND (the default of
#' [rgbif::occ_download()]); multi-valued filters become `pred_in()`.
#'
#' @param geometry_wkt WKT of the study area (from [area_to_wkt()]).
#' @param filters Normalised filters.
#' @return A list of rgbif predicates.
#' @export
build_download_predicates <- function(geometry_wkt, filters) {
  reg <- gbif_filter_registry()
  preds <- list(rgbif::pred_within(geometry_wkt))
  for (nm in names(filters)) {
    v <- filters[[nm]]
    spec <- reg[[nm]]
    p <- if (spec$type == "range") {
      .range_predicates(nm, v, spec$kind)
    } else if (spec$type == "logical" || length(v) == 1) {
      list(rgbif::pred(nm, v))
    } else {
      list(rgbif::pred_in(nm, v))
    }
    preds <- c(preds, p)
  }
  preds
}

#' Get records through a GBIF occurrence download
#'
#' Requests (or resumes) an asynchronous download, waits for it, downloads and
#' imports the SIMPLE_CSV file. The pending request key is stored in
#' `work_dir`, so an interrupted run resumes instead of requesting again.
#' Requires `GBIF_USER`, `GBIF_PWD` and `GBIF_EMAIL` environment variables.
#'
#' @param query List from [build_gbif_query()].
#' @param work_dir Directory for the pending-request file and the zip.
#' @param wait_minutes Maximum waiting time for GBIF to prepare the file.
#' @param poll_seconds Seconds between status checks.
#' @param keep_zip Keep the downloaded zip after import.
#' @return A list with `records` (tibble) and `meta` (download key, DOI, ...).
#' @export
query_gbif_download <- function(query, work_dir, wait_minutes, poll_seconds, keep_zip = FALSE) {
  missing_env <- Filter(function(v) !nzchar(Sys.getenv(v)), c("GBIF_USER", "GBIF_PWD", "GBIF_EMAIL"))
  if (length(missing_env)) {
    stop("GBIF downloads need credentials in environment variables; missing: ",
         paste(missing_env, collapse = ", "), ". Set them in ~/.Renviron.", call. = FALSE)
  }
  ensure_dir(work_dir)
  pending <- file.path(work_dir, "download_pending.yaml")
  retry <- function(fn, what) .with_retry(fn, query$max_retries, query$retry_wait_seconds, what)

  if (file.exists(pending)) {
    key <- yaml::read_yaml(pending)$download_key
    lg_info("Resuming previously requested GBIF download: ", key)
  } else {
    preds <- build_download_predicates(query$geometry, query$filters)
    lg_info("Requesting GBIF download (", .DOWNLOAD_FORMAT, ") for area '", query$area_id, "'")
    req <- do.call(rgbif::occ_download, c(preds, list(format = .DOWNLOAD_FORMAT)))
    key <- as.character(req)[1]
    yaml::write_yaml(list(download_key = key, area_id = query$area_id,
                          requested_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")), pending)
    lg_info("GBIF download requested: ", key)
  }

  deadline <- Sys.time() + wait_minutes * 60
  last <- ""
  repeat {
    meta <- retry(function() rgbif::occ_download_meta(key), "download status")
    status <- as.character(meta$status)
    if (!identical(status, last)) lg_info("GBIF download ", key, " status: ", status)
    last <- status
    if (identical(status, "SUCCEEDED")) break
    if (status %in% .DOWNLOAD_FAILED) {
      unlink(pending)
      stop("GBIF download ", key, " ended with status ", status, ". A new request will be made on the next run.", call. = FALSE)
    }
    if (Sys.time() > deadline) {
      stop("Timed out after ", wait_minutes, " min waiting for GBIF download ", key,
           " (status ", status, "). Run again to resume waiting for the same request.", call. = FALSE)
    }
    Sys.sleep(poll_seconds)
  }

  zipdir <- file.path(work_dir, "download")
  ensure_dir(zipdir)
  lg_info("Downloading file (", round(as.numeric(meta$size %||% NA) / 1e6, 1), " MB)")
  retry(function() rgbif::occ_download_get(key, path = zipdir, overwrite = TRUE), "download file")
  lg_info("Importing downloaded records")
  records <- dplyr::as_tibble(retry(function() rgbif::occ_download_import(key = key, path = zipdir), "import"))
  if ("gbifID" %in% names(records) && is.numeric(records$gbifID)) {
    records$gbifID <- format(records$gbifID, scientific = FALSE, trim = TRUE)
  }
  total <- as.numeric(meta$totalRecords %||% NA)
  if (!is.na(total) && total != NROW(records)) {
    lg_warn("Imported ", NROW(records), " records but GBIF reports ", total, " for download ", key)
  }
  if (!keep_zip) unlink(zipdir, recursive = TRUE)
  unlink(pending)
  lg_info("Records imported from download: ", NROW(records), " (DOI: ", meta$doi %||% "n/a", ")")
  list(
    records = records,
    meta = list(
      queried_at = as.character(meta$created %||% format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
      n_records = NROW(records),
      n_total_without_filters = NA_real_,
      method = "download",
      download_key = key,
      download_doi = as.character(meta$doi %||% NA),
      download_format = .DOWNLOAD_FORMAT,
      download_total_records = total,
      rgbif_version = as.character(utils::packageVersion("rgbif"))
    )
  )
}
