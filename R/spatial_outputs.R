# Spatial layers and tables ----------------------------------------------------

#' Keep only GPKG-compatible (atomic, case-insensitively unique) columns
#' @param x An `sf` object.
#' @return `x` without list columns or case-duplicated column names.
#' @keywords internal
.gpkg_safe <- function(x) {
  geomcol <- attr(x, "sf_column")
  is_list <- vapply(sf::st_drop_geometry(x), is.list, logical(1))
  if (any(is_list)) {
    lg_debug("List columns omitted from the GPKG layer: ", paste(names(is_list)[is_list], collapse = ", "))
    x <- x[, !(names(x) %in% names(is_list)[is_list])]
  }
  nm <- setdiff(names(x), geomcol)
  dup <- duplicated(tolower(nm))
  if (any(dup)) {
    lg_warn("Columns dropped from the GPKG layer (case-insensitive duplicates): ", paste(nm[dup], collapse = ", "))
    x <- x[, !(names(x) %in% nm[dup])]
  }
  x
}

#' Assemble the spatial result layers
#'
#' @param areas Study areas with `area_km2`.
#' @param records_sf Processed records.
#' @param density Density grid (`sf`) from [calculate_density()].
#' @param include_records Whether to include the (possibly huge) records layer.
#' @return A named list of `sf` layers: `areas`, `gbif_records`, `gbif_density`.
#' @export
create_spatial_layers <- function(areas, records_sf, density, include_records = TRUE) {
  if (!include_records) {
    lg_info("gbif_records layer not written (output.write_records_layer = false)")
    return(list(areas = areas, gbif_density = density))
  }
  list(areas = areas, gbif_records = .gpkg_safe(records_sf), gbif_density = density)
}

#' Write spatial layers into a single GPKG
#'
#' Refuses to overwrite an existing file. Empty layers are skipped (and logged).
#'
#' @param layers Named list of `sf` layers.
#' @param path Output GPKG path.
#' @return `path`, invisibly.
#' @export
write_spatial_layers <- function(layers, path) {
  if (file.exists(path)) stop("Refusing to overwrite existing file: ", path, call. = FALSE)
  ensure_dir(dirname(path))
  for (nm in names(layers)) {
    lyr <- layers[[nm]]
    if (is.null(lyr) || nrow(lyr) == 0) {
      lg_warn("Layer '", nm, "' is empty and was not written")
      next
    }
    sf::st_write(lyr, path, layer = nm, quiet = TRUE)
    lg_info("Layer written: ", nm, " (", nrow(lyr), " features)")
  }
  invisible(path)
}

#' Write result tables as CSV files
#'
#' @param tables Named list of data frames (list entries that are themselves
#'   lists of data frames are flattened with a `name_subname` prefix).
#' @param dir Output directory.
#' @return Character vector of written files.
#' @export
write_output_tables <- function(tables, dir) {
  ensure_dir(dir)
  flat <- list()
  for (nm in names(tables)) {
    x <- tables[[nm]]
    if (is.data.frame(x)) flat[[nm]] <- x
    else if (is.list(x)) for (sn in names(x)) if (is.data.frame(x[[sn]])) flat[[paste0(nm, "_", sn)]] <- x[[sn]]
  }
  files <- vapply(names(flat), function(nm) {
    f <- file.path(dir, paste0(nm, ".csv"))
    utils::write.csv(flat[[nm]], f, row.names = FALSE, fileEncoding = "UTF-8")
    f
  }, character(1))
  unname(files)
}
