#' Summarise occurrence records by area
#'
#' Calculates record counts, taxonomic coverage, and year coverage for each
#' requested area.
#'
#' @param records Data frame containing occurrence records.
#' @param area_ids Optional character vector of area identifiers. If `NULL`,
#'   identifiers are inferred from `records$area_id`.
#'
#' @return A data frame with one row per area and summary statistics.
#' @noRd
.filter_profile <- function(records, area_ids = NULL) {
  if (!"area_id" %in% names(records)) {
    records$area_id <- character(nrow(records))
  }
  
  ids <- area_ids %||% unique(as.character(records$area_id))
  ids <- ids[!is.na(ids) & nzchar(ids)]
  
  if (!length(ids)) {
    return(
      data.frame(
        area_id = character(),
        n_records = integer(),
        n_gbif_ids = integer(),
        n_species = integer(),
        n_genera = integer(),
        n_families = integer(),
        n_records_without_species = integer(),
        n_records_without_year = integer(),
        year_min = numeric(),
        year_max = numeric()
      )
    )
  }
  
  do.call(
    rbind,
    lapply(ids, function(id) {
      d <- records[
        !is.na(records$area_id) & records$area_id == id,
        ,
        drop = FALSE
      ]
      
      get_column <- function(name) {
        if (name %in% names(d)) {
          as.character(d[[name]])
        } else {
          rep(NA_character_, nrow(d))
        }
      }
      
      year <- suppressWarnings(as.numeric(get_column("year")))
      species <- get_column("species")
      genus <- get_column("genus")
      family <- get_column("family")
      gbif_id <- get_column("gbifID")
      
      valid_year <- is.finite(year)
      
      data.frame(
        area_id = id,
        n_records = nrow(d),
        n_gbif_ids = length(unique(
          gbif_id[!is.na(gbif_id) & nzchar(gbif_id)]
        )),
        n_species = length(unique(
          species[!is.na(species) & nzchar(species)]
        )),
        n_genera = length(unique(
          genus[!is.na(genus) & nzchar(genus)]
        )),
        n_families = length(unique(
          family[!is.na(family) & nzchar(family)]
        )),
        n_records_without_species = sum(
          is.na(species) | !nzchar(species)
        ),
        n_records_without_year = sum(!valid_year),
        year_min = if (any(valid_year)) {
          min(year[valid_year])
        } else {
          NA_real_
        },
        year_max = if (any(valid_year)) {
          max(year[valid_year])
        } else {
          NA_real_
        },
        stringsAsFactors = FALSE
      )
    })
  )
}

#' Read and validate a GBIF cache entry
#'
#' Reads the metadata and cached occurrence records for one cache entry.
#' The source cache is treated as read-only.
#'
#' @param path Cache-entry path, absolute or relative to `root`.
#' @param root Project root used to resolve relative paths.
#'
#' @return A list containing the resolved path, records, metadata, area ID,
#'   cache key, and checksums of the source files.
#' @noRd
.filter_read_cache_entry <- function(path, root) {
  entry <- resolve_path(path, root)
  
  if (!dir.exists(entry)) {
    stop(
      "Cache entry directory not found: ", entry,
      call. = FALSE
    )
  }
  
  records_file <- file.path(entry, "records.rds")
  metadata_file <- file.path(entry, "meta.yaml")
  
  if (!file.exists(records_file) || !file.exists(metadata_file)) {
    stop(
      "Cache entry must contain records.rds and meta.yaml: ", entry,
      call. = FALSE
    )
  }
  
  meta <- tryCatch(
    yaml::read_yaml(metadata_file),
    error = function(e) {
      stop(
        "Could not read cache metadata ", metadata_file, ": ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  
  if (!is.list(meta)) {
    stop(
      "Cache metadata must be a YAML mapping: ", metadata_file,
      call. = FALSE
    )
  }
  
  cache_key <- meta$cache_key
  
  if (
    is.null(cache_key) ||
    length(cache_key) != 1L ||
    is.na(cache_key) ||
    !nzchar(as.character(cache_key))
  ) {
    stop(
      "Invalid or missing cache_key in ", metadata_file,
      call. = FALSE
    )
  }
  
  schema <- suppressWarnings(as.integer(meta$cache_schema))
  
  if (
    is.null(meta$cache_schema) ||
    length(meta$cache_schema) != 1L ||
    is.na(schema) ||
    schema != .CACHE_SCHEMA_VERSION
  ) {
    stop(
      "Unsupported cache_schema in ", metadata_file,
      "; expected ", .CACHE_SCHEMA_VERSION,
      call. = FALSE
    )
  }
  
  area_id <- meta$area_id
  
  if (
    is.null(area_id) ||
    length(area_id) != 1L ||
    is.na(area_id) ||
    !nzchar(as.character(area_id))
  ) {
    stop(
      "Invalid or missing area_id in ", metadata_file,
      call. = FALSE
    )
  }
  
  entry <- normalizePath(entry, mustWork = TRUE)
  
  if (!identical(basename(entry), as.character(cache_key))) {
    stop(
      "Cache directory name does not match metadata cache_key: ",
      entry,
      call. = FALSE
    )
  }
  
  records <- tryCatch(
    readRDS(records_file),
    error = function(e) {
      stop(
        "Could not read cached records ", records_file, ": ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  
  if (!is.data.frame(records)) {
    stop(
      "records.rds must contain a data frame: ", records_file,
      call. = FALSE
    )
  }
  
  if (
    !is.null(meta$n_records) &&
    length(meta$n_records) == 1L &&
    !is.na(meta$n_records) &&
    nrow(records) != as.integer(meta$n_records)
  ) {
    stop(
      "Record count mismatch in ", entry,
      call. = FALSE
    )
  }
  
  if ("area_id" %in% names(records)) {
    present <- unique(
      as.character(records$area_id[!is.na(records$area_id)])
    )
    
    if (length(present) && any(present != as.character(area_id))) {
      stop(
        "Cached records contain area_id inconsistent with meta.yaml: ",
        entry,
        call. = FALSE
      )
    }
  }
  
  records$area_id <- rep(as.character(area_id), nrow(records))
  
  list(
    path = entry,
    records = records,
    meta = meta,
    area_id = as.character(area_id),
    cache_key = as.character(cache_key),
    records_md5 = unname(tools::md5sum(records_file)),
    meta_md5 = unname(tools::md5sum(metadata_file))
  )
}

#' Validate occurrence records before spatial filtering
#'
#' Ensures coordinate fields are numeric, removes records with missing or
#' invalid coordinates, and removes duplicated GBIF identifiers within each
#' area. Missing GBIF identifiers are not treated as duplicates.
#'
#' @param records Data frame of occurrence records.
#'
#' @return A list with `records`, containing retained records, and `removed`,
#'   containing counts by area and exclusion reason.
#' @noRd
.filter_technical_validation <- function(records) {
  removed <- data.frame(
    area_id = character(),
    reason = character(),
    n = integer(),
    stringsAsFactors = FALSE
  )

  if (!nrow(records)) {
    return(list(records = records, removed = removed))
  }

  required_columns <- c(
    "decimalLatitude",
    "decimalLongitude",
    "gbifID"
  )

  for (column in required_columns) {
    if (!column %in% names(records)) {
      records[[column]] <- if (column == "gbifID") {
        NA_character_
      } else {
        NA_real_
      }
    }
  }

  records$gbifID <- as.character(records$gbifID)

  numeric_columns <- c(
    "decimalLatitude",
    "decimalLongitude",
    "year",
    "month",
    "coordinateUncertaintyInMeters"
  )

  for (column in intersect(numeric_columns, names(records))) {
    records[[column]] <- suppressWarnings(
      as.numeric(as.character(records[[column]]))
    )
  }

  missing_taxonomy <- setdiff(.tax_cols, names(records))

  for (column in missing_taxonomy) {
    records[[column]] <- NA_character_
  }

  drop_records <- function(x, bad, reason) {
    bad[is.na(bad)] <- TRUE

    if (any(bad)) {
      counts <- as.data.frame(
        table(area_id = x$area_id[bad]),
        stringsAsFactors = FALSE
      )

      removed <<- rbind(
        removed,
        data.frame(
          area_id = as.character(counts$area_id),
          reason = reason,
          n = as.integer(counts$Freq),
          stringsAsFactors = FALSE
        )
      )
    }

    x[!bad, , drop = FALSE]
  }

  lat <- records$decimalLatitude
  lon <- records$decimalLongitude

  invalid_coordinates <- (
    !is.finite(lat) |
      !is.finite(lon)
  )

  records <- drop_records(
    records,
    invalid_coordinates,
    "missing or non-numeric coordinates"
  )

  lat <- records$decimalLatitude
  lon <- records$decimalLongitude

  out_of_range <- (
    lat < -90 |
      lat > 90 |
      lon < -180 |
      lon > 180
  )

  records <- drop_records(
    records,
    out_of_range,
    "coordinates out of valid range"
  )

  has_gbif_id <- !is.na(records$gbifID) & nzchar(records$gbifID)
  duplicated_id <- rep(FALSE, nrow(records))

  duplicated_id[has_gbif_id] <- duplicated(
    paste(
      records$area_id[has_gbif_id],
      records$gbifID[has_gbif_id],
      sep = "\r"
    )
  )

  records <- drop_records(
    records,
    duplicated_id,
    "duplicated gbifID within area"
  )

  list(
    records = records,
    removed = removed
  )
}

#' Register available occurrence filters
#'
#' @return A named list of filter definitions.
#' @noRd
.filter_registry <- function() {
  list(
    "spatial.raster" = list(
      id = "spatial.raster",
      category = "spatial",
      validate_config = function(x) {
        if (!is.list(x) || !identical(x$enabled, TRUE)) {
          stop(
            "spatial.raster.enabled must be true",
            call. = FALSE
          )
        }
        
        if (
          !is.atomic(x$accepted_values) ||
          !length(x$accepted_values) ||
          anyNA(x$accepted_values)
        ) {
          stop(
            "spatial.raster.accepted_values must be non-empty",
            call. = FALSE
          )
        }
        
        invisible(TRUE)
      },
      apply = apply_raster_occurrence_filter
    )
  )
}


#' Validate and normalise the filtering configuration
#'
#' Resolves paths and validates the required configuration fields.
#'
#' @param cfg Parsed YAML configuration.
#' @param root Project root used to resolve relative paths.
#'
#' @return A validated configuration list with resolved paths.
#' @noRd
.filter_validate_config <- function(cfg, root) {
  if (!is.list(cfg)) {
    abort_config("filter configuration must be a YAML mapping")
  }
  
  project_name <- cfg$project$name
  
  if (
    is.null(project_name) ||
    !is.character(project_name) ||
    length(project_name) != 1L ||
    is.na(project_name) ||
    !nzchar(project_name)
  ) {
    abort_config("project.name must be a non-empty string")
  }
  
  entries <- cfg$input$cache_entries
  
  if (
    !is.character(entries) ||
    !length(entries) ||
    anyNA(entries) ||
    any(!nzchar(entries))
  ) {
    abort_config(
      "input.cache_entries must be a non-empty list of cache-entry paths"
    )
  }
  
  entries <- vapply(
    entries,
    resolve_path,
    character(1),
    root = root
  )
  
  normalised_entries <- normalizePath(
    entries,
    mustWork = FALSE
  )
  
  if (anyDuplicated(normalised_entries)) {
    abort_config("input.cache_entries contains duplicate paths")
  }
  
  raster_config <- cfg$filters$spatial$raster
  
  tryCatch(
    .filter_registry()[["spatial.raster"]]$validate_config(raster_config),
    error = function(e) abort_config(conditionMessage(e))
  )
  
  if (!is.list(raster_config)) {
    abort_config("filters.spatial.raster must be a mapping")
  }
  
  raster_path <- raster_config$path
  
  if (
    !is.character(raster_path) ||
    length(raster_path) != 1L ||
    is.na(raster_path) ||
    !nzchar(raster_path)
  ) {
    abort_config(
      "filters.spatial.raster.path must be a non-empty path"
    )
  }
  
  raster_path <- resolve_path(raster_path, root)
  
  if (!file.exists(raster_path)) {
    abort_config("raster file not found: ", raster_path)
  }
  
  accepted <- raster_config$accepted_values
  
  if (!is.atomic(accepted) || !length(accepted) || anyNA(accepted)) {
    abort_config(
      "accepted_values must be a non-empty vector of discrete values"
    )
  }
  
  if (is.numeric(accepted)) {
    if (any(!is.finite(accepted))) {
      abort_config("accepted_values must be finite")
    }
  } else if (!is.character(accepted) || any(!nzchar(accepted))) {
    abort_config(
      paste(
        "accepted_values must contain finite numeric values",
        "or non-empty strings"
      )
    )
  }
  
  accepted <- unique(as.character(accepted))
  
  output_dir <- cfg$output$directory %||% "results/filtering"
  
  if (
    !is.character(output_dir) ||
    length(output_dir) != 1L ||
    is.na(output_dir) ||
    !nzchar(output_dir)
  ) {
    abort_config("output.directory must be a non-empty path")
  }
  
  analysis <- utils::modifyList(
    list(
      top_n = 10L,
      density_cell_km = 5,
      metric_crs = "auto",
      max_map_points = 50000L
    ),
    cfg$analysis %||% list()
  )
  
  list(
    project = list(name = project_name),
    input = list(cache_entries = entries),
    filters = list(
      spatial = list(
        raster = list(
          enabled = TRUE,
          path = raster_path,
          accepted_values = accepted
        )
      )
    ),
    analysis = analysis,
    output = list(directory = resolve_path(output_dir, root)),
    logging = list(
      level = normalise_log_level(cfg$logging$level %||% "INFO")
    ),
    root = root
  )
}

#' Filter occurrence records using a discrete raster
#'
#' Extracts the raster cell value at each occurrence coordinate and retains
#' records whose cell values match the accepted codes. The raster must have
#' exactly one layer and an explicitly defined EPSG:4326 coordinate
#' reference system. No automatic reprojection is performed.
#'
#' For categorical rasters, category labels can be supplied when the raster
#' exposes an explicit category table.
#'
#' @param records Data frame of technically validated occurrence records,
#'   including `decimalLongitude` and `decimalLatitude`.
#' @param raster_path Path to a single-layer raster.
#' @param accepted_values Vector of accepted discrete cell codes or
#'   recognised category labels.
#'
#' @return A list containing:
#'   \describe{
#'     \item{records}{Retained occurrence records.}
#'     \item{removed}{Counts of excluded records by area and reason.}
#'     \item{raster}{Raster metadata, including its checksum.}
#'     \item{n_input}{Number of records received.}
#'     \item{n_retained}{Number of records retained.}
#'     \item{n_removed}{Number of records excluded.}
#'   }
#'
#' @export
apply_raster_occurrence_filter <- function(
    records,
    raster_path,
    accepted_values
) {
  r <- tryCatch(
    terra::rast(raster_path),
    error = function(e) {
      stop(
        "Could not open raster ", raster_path, ": ",
        conditionMessage(e),
        call. = FALSE
      )
    }
  )
  
  if (terra::nlyr(r) != 1L) {
    stop(
      "Raster filter requires exactly one layer/band.",
      call. = FALSE
    )
  }
  
  crs_text <- terra::crs(r)
  
  if (is.null(crs_text) || !nzchar(crs_text)) {
    stop(
      "Raster CRS is missing; raster must use EPSG:4326.",
      call. = FALSE
    )
  }
  
  crs_obj <- tryCatch(
    sf::st_crs(crs_text),
    error = function(e) NA
  )
  
  if (
    is.na(crs_obj) ||
    is.null(crs_obj$epsg) ||
    is.na(crs_obj$epsg) ||
    crs_obj$epsg != 4326L
  ) {
    stop(
      paste(
        "Raster CRS must be explicitly EPSG:4326;",
        "automatic reprojection is disabled."
      ),
      call. = FALSE
    )
  }
  
  xmin_r <- terra::xmin(r)
  xmax_r <- terra::xmax(r)
  ymin_r <- terra::ymin(r)
  ymax_r <- terra::ymax(r)
  
  raster_extent <- terra::ext(r)
  
  raster_meta <- list(
    path = normalizePath(raster_path, mustWork = TRUE),
    crs = "EPSG:4326",
    nlyr = terra::nlyr(r),
    resolution = as.numeric(terra::res(r)),
    extent = as.vector(raster_extent),
    datatype = paste(terra::datatype(r), collapse = ","),
    md5 = unname(tools::md5sum(raster_path)),
    accepted_values = accepted_values
  )
  
  if (!nrow(records)) {
    return(
      list(
        records = records,
        removed = data.frame(
          area_id = character(),
          reason = character(),
          n = integer(),
          stringsAsFactors = FALSE
        ),
        raster = raster_meta,
        n_input = 0L,
        n_retained = 0L,
        n_removed = 0L
      )
    )
  }
  
  lon <- suppressWarnings(
    as.numeric(as.character(records$decimalLongitude))
  )
  
  lat <- suppressWarnings(
    as.numeric(as.character(records$decimalLatitude))
  )
  
  in_extent <- (
    is.finite(lon) &
      is.finite(lat) &
      lon >= xmin_r &
      lon <= xmax_r &
      lat >= ymin_r &
      lat <= ymax_r
  )
  
  values <- rep(NA_real_, nrow(records))
  
  if (any(in_extent)) {
    extracted <- terra::extract(
      r,
      cbind(lon[in_extent], lat[in_extent])
    )
    
    # The raster has exactly one layer. With matrix coordinates and the
    # default ID = FALSE, the returned data frame contains the layer value.
    value_col <- extracted[[1L]]
    
    if (is.factor(value_col) || is.character(value_col)) {
      category_tables <- tryCatch(
        terra::cats(r),
        error = function(e) NULL
      )
      
      categories <- if (length(category_tables)) {
        category_tables[[1L]]
      } else {
        NULL
      }
      
      if (!is.null(categories) && ncol(categories) >= 2L) {
        code_col <- names(categories)[1L]
        category_cols <- setdiff(names(categories), code_col)
        
        labels <- as.character(value_col)
        codes <- rep(NA_real_, length(labels))
        
        for (j in seq_along(labels)) {
          matches <- which(
            Reduce(
              `|`,
              lapply(
                category_cols,
                function(column) {
                  as.character(categories[[column]]) == labels[j]
                }
              )
            )
          )
          
          if (length(matches)) {
            codes[j] <- suppressWarnings(
              as.numeric(
                as.character(categories[[code_col]][matches[1L]])
              )
            )
          }
        }
        
        values[in_extent] <- codes
      } else {
        values[in_extent] <- suppressWarnings(
          as.numeric(as.character(value_col))
        )
      }
    } else {
      values[in_extent] <- suppressWarnings(
        as.numeric(value_col)
      )
    }
  }
  
  reason <- rep("outside raster extent", nrow(records))
  
  reason[in_extent & is.na(values)] <-
    "raster NoData / unavailable value"
  
  valid <- in_extent & !is.na(values) & is.finite(values)
  
  reason[valid] <- "raster value not accepted"
  
  accepted_numeric <- suppressWarnings(
    as.numeric(accepted_values)
  )
  
  if (all(is.finite(accepted_numeric))) {
    accepted_codes <- accepted_numeric
  } else {
    category_tables <- tryCatch(
      terra::cats(r),
      error = function(e) NULL
    )
    
    categories <- if (length(category_tables)) {
      category_tables[[1L]]
    } else {
      NULL
    }
    
    if (is.null(categories) || ncol(categories) < 2L) {
      stop(
        paste(
          "accepted_values must be numeric raster cell codes,",
          "or category labels present in the raster category table."
        ),
        call. = FALSE
      )
    }
    
    code_col <- names(categories)[1L]
    category_cols <- setdiff(names(categories), code_col)
    accepted_codes <- numeric()
    
    for (value in accepted_values) {
      numeric_value <- suppressWarnings(as.numeric(value))
      
      if (length(numeric_value) == 1L && is.finite(numeric_value)) {
        accepted_codes <- c(accepted_codes, numeric_value)
      } else {
        matches <- which(
          Reduce(
            `|`,
            lapply(
              category_cols,
              function(column) {
                as.character(categories[[column]]) == value
              }
            )
          )
        )
        
        if (!length(matches)) {
          stop(
            "Raster category label not found: ", value,
            call. = FALSE
          )
        }
        
        accepted_codes <- c(
          accepted_codes,
          suppressWarnings(
            as.numeric(as.character(categories[[code_col]][matches]))
          )
        )
      }
    }
    
    if (!length(accepted_codes) || any(!is.finite(accepted_codes))) {
      stop(
        "Could not resolve accepted_values to raster cell codes.",
        call. = FALSE
      )
    }
  }
  
  keep <- valid & values %in% accepted_codes
  reason[keep] <- NA_character_
  
  removed <- data.frame(
    area_id = character(),
    reason = character(),
    n = integer(),
    stringsAsFactors = FALSE
  )
  
  if (any(!keep)) {
    counts <- as.data.frame(
      table(
        area_id = records$area_id[!keep],
        reason = reason[!keep]
      ),
      stringsAsFactors = FALSE
    )
    
    counts <- counts[counts$Freq > 0, , drop = FALSE]
    
    removed <- data.frame(
      area_id = as.character(counts$area_id),
      reason = as.character(counts$reason),
      n = as.integer(counts$Freq),
      stringsAsFactors = FALSE
    )
  }
  
  list(
    records = records[keep, , drop = FALSE],
    removed = removed,
    raster = raster_meta,
    n_input = nrow(records),
    n_retained = sum(keep),
    n_removed = sum(!keep)
  )
}

#' Flatten list columns for tabular export
#'
#' Converts list-column elements to character strings so they can be written
#' to CSV without losing their contents.
#'
#' @param x Data frame to flatten.
#'
#' @return A data frame with list columns converted to character columns.
#' @noRd
.filter_flatten_list_columns <- function(x) {
  x <- as.data.frame(x)
  
  for (column in names(x)) {
    if (is.list(x[[column]]) && !is.data.frame(x[[column]])) {
      values <- x[[column]]
      
      x[[column]] <- vapply(
        seq_along(values),
        function(i) {
          value <- values[[i]]
          
          if (is.null(value) || !length(value)) {
            NA_character_
          } else {
            paste(capture.output(dput(value)), collapse = "")
          }
        },
        character(1)
      )
    }
  }
  
  x
}


#' Write a data frame to CSV
#'
#' @param x Data frame to export.
#' @param path Destination CSV path.
#'
#' @return The output path, invisibly.
#' @noRd
.filter_write_csv <- function(x, path) {
  utils::write.csv(
    .filter_flatten_list_columns(x),
    path,
    row.names = FALSE,
    na = ""
  )
  
  invisible(path)
}


#' Normalise Windows path separators in report context
#'
#' Recursively converts backslashes to forward slashes in character values
#' before they are interpolated into a LaTeX report.
#'
#' @param x Report context object.
#'
#' @return The context object with normalised character values.
#' @noRd
.filter_normalize_report_context <- function(x) {
  if (is.data.frame(x)) {
    for (column in names(x)) {
      if (is.character(x[[column]])) {
        x[[column]] <- gsub("\\\\", "/", x[[column]])
      } else if (is.list(x[[column]])) {
        x[[column]] <- lapply(
          x[[column]],
          .filter_normalize_report_context
        )
      }
    }
    
    return(x)
  }
  
  if (is.list(x)) {
    return(lapply(x, .filter_normalize_report_context))
  }
  
  if (is.character(x)) {
    return(gsub("\\\\", "/", x))
  }
  
  x
}

#' Run independent post-retrieval GBIF occurrence filtering
#'
#' Executes the filtering workflow using existing cached GBIF records.
#' The workflow does not query the GBIF API and treats source cache entries
#' as read-only.
#'
#' @param config_path Path to the filtering YAML configuration.
#' @param root Project root used to resolve paths and locate report resources.
#'
#' @return Integer process status: `0` on success and `1` on failure.
#'
#' @export
run_filtering <- function(config_path, root) {
  collector <- setup_logging("INFO")
  state <- new.env(parent = emptyenv())
  
  ok <- tryCatch(
    {
      withCallingHandlers(
        .run_filtering_pipeline(
          config_path = config_path,
          root = root,
          collector = collector,
          state = state
        ),
        warning = function(w) {
          lg_warn("R warning: ", conditionMessage(w))
          invokeRestart("muffleWarning")
        }
      )
      
      TRUE
    },
    error = function(e) {
      lg_error(conditionMessage(e))
      lg_error("Filtering aborted; no final report was produced.")
      
      if (!is.null(state$run_dir) && dir.exists(state$run_dir)) {
        try(
          yaml::write_yaml(
            list(
              status = "failed",
              error = conditionMessage(e),
              finished_at = format(
                Sys.time(),
                "%Y-%m-%dT%H:%M:%S%z"
              )
            ),
            file.path(state$run_dir, "run_status.yaml")
          ),
          silent = TRUE
        )
      }
      
      FALSE
    }
  )
  
  if (ok) 0L else 1L
}

#' Run the independent GBIF occurrence filtering pipeline
#'
#' Loads existing GBIF cache entries, performs technical validation,
#' applies the configured raster filter, writes tabular and spatial outputs,
#' verifies that source cache files remain unchanged, and renders a PDF report.
#'
#' No GBIF API requests are made. Source cache entries are treated as read-only.
#'
#' @param config_path Path to the filtering YAML configuration.
#' @param root Project root directory.
#' @param collector Logging collector containing messages and warnings.
#' @param state Environment used to preserve run state after an error.
#'
#' @return Invisibly returns `TRUE` if the pipeline completes successfully.
#'
#' @noRd
.run_filtering_pipeline <- function(
    config_path,
    root,
    collector,
    state
) {
  started <- Sys.time()
  timings <- new.env(parent = emptyenv())
  
  # Validate configuration ---------------------------------------------------
  cfg <- .filter_validate_config(
    read_config(config_path),
    root
  )
  
  set_log_level(cfg$logging$level)
  
  # Initialise run directory -------------------------------------------------
  run_stamp <- format(started, "%Y%m%d_%H%M%S")
  run_id <- run_stamp
  
  run_dir <- file.path(
    cfg$output$directory,
    paste0("run_", run_id)
  )
  
  suffix <- 1L
  
  while (dir.exists(run_dir)) {
    run_id <- paste0(run_stamp, "_", suffix)
    suffix <- suffix + 1L
    
    run_dir <- file.path(
      cfg$output$directory,
      paste0("run_", run_id)
    )
  }
  
  state$run_dir <- run_dir
  
  output_dirs <- c(
    "figures",
    "spatial",
    "tables",
    "logs",
    "report"
  )
  
  for (directory in output_dirs) {
    ensure_dir(file.path(run_dir, directory))
  }
  
  add_log_file(
    file.path(
      run_dir,
      "logs",
      paste0("filtering_", run_id, ".log")
    )
  )
  
  # Preserve configuration ---------------------------------------------------
  original_config <- file.path(
    run_dir,
    "config_original.yaml"
  )
  
  if (!file.copy(config_path, original_config, overwrite = FALSE)) {
    stop(
      "Could not copy original configuration.",
      call. = FALSE
    )
  }
  
  cfg_eff <- cfg
  cfg_eff$root <- NULL
  
  yaml::write_yaml(
    cfg_eff,
    file.path(run_dir, "config_effective.yaml")
  )
  
  lg_info(
    "Starting independent GBIF occurrence filtering; ",
    "no GBIF API calls will be made"
  )
  
  # Load and validate cache entries -----------------------------------------
  entries <- run_step(
    "load and validate cache entries",
    lapply(
      cfg$input$cache_entries,
      .filter_read_cache_entry,
      root = root
    ),
    timings
  )
  
  paths <- vapply(entries, `[[`, character(1), "path")
  ids <- vapply(entries, `[[`, character(1), "area_id")
  
  if (anyDuplicated(paths)) {
    stop(
      "Duplicate cache entry paths are not allowed.",
      call. = FALSE
    )
  }
  
  duplicated_ids <- unique(ids[duplicated(ids)])
  
  if (length(duplicated_ids)) {
    stop(
      "Duplicate area_id values among cache entries are ambiguous: ",
      paste(duplicated_ids, collapse = ", "),
      call. = FALSE
    )
  }
  
  # Record input provenance --------------------------------------------------
  input_entries <- do.call(
    rbind,
    lapply(entries, function(entry) {
      filters <- entry$meta$filters %||% list()
      
      filters_text <- if (length(filters)) {
        paste(
          vapply(
            names(filters),
            function(name) {
              paste0(
                name,
                "=",
                paste(unlist(filters[[name]]), collapse = ",")
              )
            },
            character(1)
          ),
          collapse = "; "
        )
      } else {
        ""
      }
      
      method <- entry$meta$method %||%
        entry$meta$query_method %||%
        if (!is.null(entry$meta$download_key)) {
          "download"
        } else {
          "search"
        }
      
      data.frame(
        area_id = entry$area_id,
        cache_key = entry$cache_key,
        cache_entry = entry$path,
        source_records = nrow(entry$records),
        n_total_without_filters = as.numeric(
          entry$meta$n_total_without_filters %||% NA_real_
        ),
        queried_at = as.character(
          entry$meta$queried_at %||% NA
        ),
        method = as.character(method),
        filters = filters_text,
        download_doi = as.character(
          entry$meta$download_doi %||% NA
        ),
        records_md5_before = entry$records_md5,
        meta_md5_before = entry$meta_md5,
        stringsAsFactors = FALSE
      )
    })
  )
  
  # Build combined dataset and raw profile ----------------------------------
  raw <- bind_records(
    lapply(entries, `[[`, "records")
  )
  
  profile_raw <- .filter_profile(raw, ids)
  
  lg_info("Raw records loaded from cache: ", nrow(raw))
  
  # Technical validation ----------------------------------------------------
  validated <- run_step(
    "technical validation",
    .filter_technical_validation(raw),
    timings
  )
  
  before <- validated$records
  profile_before <- .filter_profile(before, ids)
  
  tech_removed <- validated$removed
  
  if (nrow(tech_removed)) {
    tech_removed$stage <- "technical_validation"
  }
  
  # Apply configured raster filter -----------------------------------------
  filter_def <- .filter_registry()[["spatial.raster"]]
  
  raster_result <- run_step(
    paste0("apply filter ", filter_def$id),
    filter_def$apply(
      before,
      cfg$filters$spatial$raster$path,
      cfg$filters$spatial$raster$accepted_values
    ),
    timings
  )
  
  after <- raster_result$records
  profile_after <- .filter_profile(after, ids)
  
  raster_removed <- raster_result$removed
  
  if (nrow(raster_removed)) {
    raster_removed$stage <- "spatial.raster"
  }
  
  # Combine removal records -------------------------------------------------
  empty_removed <- data.frame(
    area_id = character(),
    reason = character(),
    n = integer(),
    stage = character(),
    stringsAsFactors = FALSE
  )
  
  technical_removals <- if (nrow(tech_removed)) {
    data.frame(
      area_id = tech_removed$area_id,
      reason = tech_removed$reason,
      n = tech_removed$n,
      stage = tech_removed$stage,
      stringsAsFactors = FALSE
    )
  } else {
    empty_removed
  }
  
  raster_removals <- if (nrow(raster_removed)) {
    data.frame(
      area_id = raster_removed$area_id,
      reason = raster_removed$reason,
      n = raster_removed$n,
      stage = raster_removed$stage,
      stringsAsFactors = FALSE
    )
  } else {
    empty_removed
  }
  
  removed <- rbind(
    technical_removals,
    raster_removals
  )
  
  # Summarise filtering results ---------------------------------------------
  summary <- do.call(
    rbind,
    lapply(ids, function(id) {
      n_before <- sum(before$area_id == id, na.rm = TRUE)
      n_after <- sum(after$area_id == id, na.rm = TRUE)
      n_raw <- sum(raw$area_id == id, na.rm = TRUE)
      
      data.frame(
        area_id = id,
        filter_id = "spatial.raster",
        input_records = n_before,
        retained_records = n_after,
        removed_records = n_before - n_after,
        technical_removed_before_filter = n_raw - n_before,
        stringsAsFactors = FALSE
      )
    })
  )
  
  if (!nrow(after)) {
    lg_warn(
      "No records remain after filtering; ",
      "producing empty outputs and report"
    )
  }
  
  # Generate before-and-after plot -----------------------------------------
  run_step(
    "create before-after profile plot",
    {
      plot_data <- rbind(
        transform(profile_raw, profile = "Raw cache"),
        transform(profile_before, profile = "Technically valid"),
        transform(profile_after, profile = "Raster retained")
      )
      
      plot <- ggplot2::ggplot(
        plot_data,
        ggplot2::aes(
          x = area_id,
          y = n_records,
          fill = profile
        )
      ) +
        ggplot2::geom_col(position = "dodge") +
        ggplot2::labs(
          title = "GBIF occurrence records by filtering stage",
          x = "Area",
          y = "Records",
          fill = "Stage"
        ) +
        ggplot2::theme_minimal() +
        ggplot2::theme(
          axis.text.x = ggplot2::element_text(
            angle = 45,
            hjust = 1
          )
        )
      
      ggplot2::ggsave(
        filename = file.path(
          run_dir,
          "figures",
          "record_counts_before_after.png"
        ),
        plot = plot,
        width = max(7, 1.2 * length(ids)),
        height = 5,
        dpi = 160
      )
    },
    timings
  )
  
  # Write tabular and spatial outputs --------------------------------------
  run_step(
    "write filtering outputs",
    {
      tables_dir <- file.path(run_dir, "tables")
      
      .filter_write_csv(
        input_entries,
        file.path(tables_dir, "input_entries.csv")
      )
      
      .filter_write_csv(
        profile_raw,
        file.path(tables_dir, "profile_raw.csv")
      )
      
      .filter_write_csv(
        profile_before,
        file.path(tables_dir, "profile_before_filter.csv")
      )
      
      .filter_write_csv(
        profile_after,
        file.path(tables_dir, "profile_after_filter.csv")
      )
      
      .filter_write_csv(
        summary,
        file.path(tables_dir, "filter_summary.csv")
      )
      
      .filter_write_csv(
        removed,
        file.path(tables_dir, "removed_records.csv")
      )
      
      saveRDS(
        after,
        file.path(tables_dir, "records_filtered.rds")
      )
      
      .filter_write_csv(
        after,
        file.path(tables_dir, "records_filtered.csv")
      )
      
      if (nrow(after)) {
        sf::st_write(
          records_to_sf(
            .filter_flatten_list_columns(after)
          ),
          file.path(
            run_dir,
            "spatial",
            "records_filtered.gpkg"
          ),
          layer = "records_filtered",
          quiet = TRUE,
          delete_dsn = TRUE
        )
      }
    },
    timings
  )
  
  # Verify source cache immutability ---------------------------------------
  input_entries$records_md5_after <- vapply(
    entries,
    function(entry) {
      unname(
        tools::md5sum(
          file.path(entry$path, "records.rds")
        )
      )
    },
    character(1)
  )
  
  input_entries$meta_md5_after <- vapply(
    entries,
    function(entry) {
      unname(
        tools::md5sum(
          file.path(entry$path, "meta.yaml")
        )
      )
    },
    character(1)
  )
  
  records_unchanged <- (
    input_entries$records_md5_before ==
      input_entries$records_md5_after
  )
  
  metadata_unchanged <- (
    input_entries$meta_md5_before ==
      input_entries$meta_md5_after
  )
  
  if (
    anyNA(records_unchanged) ||
    anyNA(metadata_unchanged) ||
    any(!records_unchanged) ||
    any(!metadata_unchanged)
  ) {
    stop(
      "Raw cache immutability check failed.",
      call. = FALSE
    )
  }
  
  .filter_write_csv(
    input_entries,
    file.path(run_dir, "tables", "input_entries.csv")
  )
  
  # Collect execution metadata ---------------------------------------------
  env <- environment_info(root)
  
  env$package_versions$terra <- tryCatch(
    as.character(utils::packageVersion("terra")),
    error = function(e) NA_character_
  )
  
  ctx <- list(
    project = cfg$project$name,
    run_id = run_id,
    run_dir = run_dir,
    generated_at = format(
      Sys.time(),
      "%Y-%m-%d %H:%M:%S %Z"
    ),
    tool_version = get_tool_version(root),
    git = git_info(root),
    environment = env,
    config = cfg_eff,
    input_entries = input_entries,
    profile_raw = profile_raw,
    profile_before_filter = profile_before,
    profile_after_filter = profile_after,
    filter_summary = summary,
    removed_records = removed,
    raster = raster_result$raster,
    warnings = collector$store$msgs,
    timings = as.list(timings),
    limitations = c(
      paste(
        "Profiles describe GBIF record availability,",
        "not true biodiversity."
      ),
      paste(
        "The filter uses exact discrete raster cell-code matching",
        "and does not validate ecological correctness."
      ),
      paste(
        "No GBIF API requests were made;",
        "source cache files were treated as read-only."
      )
    )
  )
  
  # Save context and render PDF report --------------------------------------
  context_file <- file.path(
    run_dir,
    "tables",
    "run_context.rds"
  )
  
  # Prevent Windows path separators from being interpreted as LaTeX commands.
  ctx <- .filter_normalize_report_context(ctx)
  saveRDS(ctx, context_file)
  
  run_step(
    "render filtering PDF report",
    render_report(
      context_file,
      file.path(
        root,
        "report",
        "filtering_report_template.Rmd"
      ),
      file.path(
        run_dir,
        "report",
        "filtering_report.pdf"
      )
    ),
    timings
  )
  
  # Mark run as completed ---------------------------------------------------
  duration <- round(
    as.numeric(
      difftime(Sys.time(), started, units = "secs")
    ),
    1
  )
  
  yaml::write_yaml(
    list(
      status = "completed",
      run_id = run_id,
      duration_seconds = duration,
      finished_at = format(
        Sys.time(),
        "%Y-%m-%dT%H:%M:%S%z"
      )
    ),
    file.path(run_dir, "run_status.yaml")
  )
  
  lg_info(
    "Filtering completed successfully (",
    duration,
    " s). Results: ",
    run_dir
  )
  
  invisible(TRUE)
}