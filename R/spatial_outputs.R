# Spatial layers and tables ----------------------------------------------------

#' Drop columns that cannot be written to a spatial file
#'
#' List columns are always dropped; for GPKG, columns whose names collide
#' case-insensitively are dropped too (SQLite column names are case-insensitive).
#'
#' @param x An `sf` object.
#' @param drop_case_duplicates Drop case-insensitive duplicate names (GPKG).
#' @return `x` without the unsupported columns.
#' @keywords internal
.safe_columns <- function(x, drop_case_duplicates = FALSE) {
  geomcol <- attr(x, "sf_column")
  is_list <- vapply(sf::st_drop_geometry(x), is.list, logical(1))
  if (any(is_list)) {
    lg_debug("List columns omitted from the spatial layer: ", paste(names(is_list)[is_list], collapse = ", "))
    x <- x[, !(names(x) %in% names(is_list)[is_list])]
  }
  if (drop_case_duplicates) {
    nm <- setdiff(names(x), geomcol)
    dup <- duplicated(tolower(nm))
    if (any(dup)) {
      lg_warn("Columns dropped from the GPKG layer (case-insensitive duplicates): ", paste(nm[dup], collapse = ", "))
      x <- x[, !(names(x) %in% nm[dup])]
    }
  }
  x
}

.gpkg_safe <- function(x) .safe_columns(x, TRUE)

.SPATIAL_FORMATS <- c("geoparquet", "gpkg")

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
  list(areas = areas, gbif_records = records_sf, gbif_density = density)
}

#' Write one sf layer as a GeoParquet 1.0 file
#'
#' Geometries are stored as WKB with `geo` metadata (version 1.0.0, primary
#' column `geometry`, bbox, geometry types). Only EPSG:4326 layers are accepted;
#' the `crs` key is omitted, which in GeoParquet means OGC:CRS84 (WGS 84 lon/lat).
#' Requires the `arrow` package.
#'
#' @param x An `sf` object in EPSG:4326 with at least one row.
#' @param path Output `.parquet` path.
#' @return `path`, invisibly.
#' @export
write_geoparquet <- function(x, path) {
  if (!requireNamespace("arrow", quietly = TRUE)) {
    stop("Package 'arrow' is required for GeoParquet output (or set output.spatial_format: \"gpkg\").", call. = FALSE)
  }
  crs <- sf::st_crs(x)
  if (is.na(crs) || crs != sf::st_crs(4326)) stop("GeoParquet output supports EPSG:4326 layers only.", call. = FALSE)
  x <- .safe_columns(x)
  geom <- sf::st_geometry(x)
  df <- sf::st_drop_geometry(x)
  if ("geometry" %in% names(df)) names(df)[names(df) == "geometry"] <- "geometry_attr"
  type_map <- c(POINT = "Point", MULTIPOINT = "MultiPoint", LINESTRING = "LineString", MULTILINESTRING = "MultiLineString",
                POLYGON = "Polygon", MULTIPOLYGON = "MultiPolygon", GEOMETRYCOLLECTION = "GeometryCollection")
  types <- sort(unique(unname(type_map[as.character(sf::st_geometry_type(geom))])))
  bb <- unname(as.numeric(sf::st_bbox(geom)))
  geo <- sprintf('{"version":"1.0.0","primary_column":"geometry","columns":{"geometry":{"encoding":"WKB","geometry_types":[%s],"bbox":[%s]}}}',
                 paste0('"', types, '"', collapse = ","), paste(format(bb, digits = 17, trim = TRUE), collapse = ","))
  wkb <- unclass(sf::st_as_binary(geom))
  attributes(wkb) <- NULL
  tab <- do.call(arrow::arrow_table, c(as.list(df), list(geometry = arrow::Array$create(wkb, type = arrow::binary()))))
  tab <- tab$ReplaceSchemaMetadata(list(geo = geo))
  arrow::write_parquet(tab, path)
  invisible(path)
}

#' Write spatial layers as GeoParquet files or a single GPKG
#'
#' Refuses to overwrite existing files. Empty layers are skipped (and logged).
#'
#' @param layers Named list of `sf` layers.
#' @param dir Output directory.
#' @param name Base name of the GPKG file (`<name>.gpkg`); GeoParquet writes one `<layer>.parquet` per layer.
#' @param format `"geoparquet"` or `"gpkg"`.
#' @return Character vector of written files.
#' @export
write_spatial_layers <- function(layers, dir, name, format = "geoparquet") {
  if (!format %in% .SPATIAL_FORMATS) stop("Unsupported spatial format: ", format, call. = FALSE)
  ensure_dir(dir)
  files <- character()
  for (nm in names(layers)) {
    lyr <- layers[[nm]]
    if (is.null(lyr) || nrow(lyr) == 0) {
      lg_warn("Layer '", nm, "' is empty and was not written")
      next
    }
    if (format == "gpkg") {
      path <- file.path(dir, paste0(name, ".gpkg"))
      if (!path %in% files && file.exists(path)) stop("Refusing to overwrite existing file: ", path, call. = FALSE)
      sf::st_write(.gpkg_safe(lyr), path, layer = nm, quiet = TRUE)
    } else {
      path <- file.path(dir, paste0(nm, ".parquet"))
      if (file.exists(path)) stop("Refusing to overwrite existing file: ", path, call. = FALSE)
      write_geoparquet(lyr, path)
    }
    files <- union(files, path)
    lg_info("Layer written (", format, "): ", nm, " (", nrow(lyr), " features)")
  }
  invisible(files)
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
