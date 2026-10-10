# Processing of raw GBIF records -----------------------------------------------

.tax_cols <- c("kingdom", "phylum", "class", "order", "family", "genus", "species", "scientificName")

#' Combine the raw records of several areas
#'
#' Adds `area_id` to each area's records and binds them (types harmonised).
#'
#' @param records_list Named list (names = area ids) of raw record tables.
#' @return A tibble with an `area_id` column (zero rows if nothing was found).
#' @export
combine_area_records <- function(records_list) {
  parts <- lapply(names(records_list), function(id) {
    r <- records_list[[id]]
    if (is.null(r) || NROW(r) == 0) return(NULL)
    r <- dplyr::as_tibble(r)
    r$area_id <- id
    r
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0) return(dplyr::tibble(area_id = character()))
  bind_records(parts)
}

#' Validate and clean coordinates of raw records
#'
#' Only technical checks are applied: missing/non-numeric coordinates,
#' coordinates outside valid ranges and duplicated `gbifID` within an area.
#' No scientific filtering is done. Removals are counted by reason.
#'
#' @param records Combined records from [combine_area_records()].
#' @return A list with `records` (cleaned) and `removed` (data frame with
#'   `area_id`, `reason`, `n`).
#' @export
validate_records <- function(records) {
  removed <- data.frame(area_id = character(), reason = character(), n = integer(),
                        stringsAsFactors = FALSE)
  if (NROW(records) == 0) return(list(records = records, removed = removed))
  for (cl in c("decimalLatitude", "decimalLongitude", "gbifID")) {
    if (!cl %in% names(records)) records[[cl]] <- if (cl == "gbifID") NA_character_ else NA_real_
  }
  records$gbifID <- as.character(records$gbifID)
  for (cl in c("decimalLatitude", "decimalLongitude", "year", "month", "coordinateUncertaintyInMeters")) {
    if (cl %in% names(records)) records[[cl]] <- suppressWarnings(as.numeric(records[[cl]]))
  }
  for (cl in setdiff(.tax_cols, names(records))) records[[cl]] <- NA_character_

  drop <- function(rec, bad, reason) {
    if (any(bad)) {
      tab <- as.data.frame(table(area_id = rec$area_id[bad]), stringsAsFactors = FALSE)
      removed <<- rbind(removed, data.frame(area_id = tab$area_id, reason = reason, n = as.integer(tab$Freq),
                                            stringsAsFactors = FALSE))
      lg_warn("Removed ", sum(bad), " record(s): ", reason)
    }
    rec[!bad, , drop = FALSE]
  }
  lat <- records$decimalLatitude; lon <- records$decimalLongitude
  records <- drop(records, !is.finite(lat) | !is.finite(lon), "missing or non-numeric coordinates")
  lat <- records$decimalLatitude; lon <- records$decimalLongitude
  records <- drop(records, lat < -90 | lat > 90 | lon < -180 | lon > 180, "coordinates out of valid range")
  records <- drop(records, duplicated(paste(records$area_id, records$gbifID)), "duplicated gbifID within area")
  list(records = records, removed = removed)
}

#' Convert records to an `sf` point object (EPSG:4326)
#'
#' @param records Cleaned records with `decimalLongitude`/`decimalLatitude`.
#' @return An `sf` object; original columns (including `gbifID`) are kept.
#' @export
records_to_sf <- function(records) {
  if (NROW(records) == 0) {
    return(sf::st_sf(records, geometry = sf::st_sfc(crs = 4326)))
  }
  sf::st_as_sf(records, coords = c("decimalLongitude", "decimalLatitude"), crs = 4326, remove = FALSE)
}

#' Verify that each record lies inside the area it was queried for
#'
#' Points outside the polygon (e.g. boundary effects of the remote spatial
#' filter) are removed and counted.
#'
#' @param records_sf Records from [records_to_sf()] with `area_id`.
#' @param areas Study areas (`sf`, EPSG:4326).
#' @return A list with `records` and `removed` (same format as [validate_records()]).
#' @export
assign_records_to_areas <- function(records_sf, areas) {
  removed <- data.frame(area_id = character(), reason = character(), n = integer(), stringsAsFactors = FALSE)
  if (nrow(records_sf) == 0) return(list(records = records_sf, removed = removed))
  keep <- rep(FALSE, nrow(records_sf))
  for (id in areas$area_id) {
    idx <- which(records_sf$area_id == id)
    if (length(idx) == 0) next
    poly <- sf::st_geometry(areas[areas$area_id == id, ])
    keep[idx] <- lengths(sf::st_intersects(sf::st_geometry(records_sf)[idx], poly)) > 0
  }
  if (any(!keep)) {
    tab <- as.data.frame(table(area_id = records_sf$area_id[!keep]), stringsAsFactors = FALSE)
    removed <- data.frame(area_id = tab$area_id, reason = "outside area polygon", n = as.integer(tab$Freq),
                          stringsAsFactors = FALSE)
    lg_warn("Removed ", sum(!keep), " record(s) lying outside their area polygon")
  }
  list(records = records_sf[keep, ], removed = removed)
}
