# Study-area input -------------------------------------------------------------

.id_candidates <- c("area_id", "id", "name", "nome", "area", "site", "label")

#' Standardise study-area polygons
#'
#' Validates geometry types, CRS and validity, resolves identifiers and
#' returns polygons in EPSG:4326 with a single `area_id` column.
#'
#' @param x An `sf` object with polygon geometries.
#' @param id_column Optional name of the identifier column.
#' @param fix_invalid Logical; repair invalid geometries with
#'   [sf::st_make_valid()] (explicit opt-in).
#' @return An `sf` object with columns `area_id` and `geometry` (EPSG:4326).
#' @export
prepare_areas <- function(x, id_column = NULL, fix_invalid = FALSE) {
  if (nrow(x) == 0) stop("The area input has no features.", call. = FALSE)
  if (is.na(sf::st_crs(x))) stop("The area input has no CRS; define one before use.", call. = FALSE)
  x <- sf::st_zm(x)
  types <- as.character(sf::st_geometry_type(x))
  if (!all(types %in% c("POLYGON", "MULTIPOLYGON"))) {
    stop("Only POLYGON/MULTIPOLYGON geometries are accepted; found: ",
         paste(unique(types), collapse = ", "), call. = FALSE)
  }
  if (any(sf::st_is_empty(x))) stop("The area input contains empty geometries.", call. = FALSE)

  # identifiers
  ids <- NULL
  if (!is.null(id_column)) {
    if (!id_column %in% names(x)) stop("id_column '", id_column, "' not found in the area input.", call. = FALSE)
    ids <- as.character(x[[id_column]])
    if (anyNA(ids) || any(!nzchar(ids)) || anyDuplicated(ids)) {
      stop("id_column '", id_column, "' must have unique, non-empty values.", call. = FALSE)
    }
    lg_info("Area identifiers taken from column '", id_column, "'")
  } else {
    nms <- names(x)[match(.id_candidates, tolower(names(x)))]
    for (col in stats::na.omit(nms)) {
      v <- as.character(x[[col]])
      if (!anyNA(v) && all(nzchar(v)) && !anyDuplicated(v)) { ids <- v; lg_info("Area identifiers taken from column '", col, "'"); break }
    }
    if (is.null(ids)) {
      ids <- sprintf(paste0("area_%0", max(2, nchar(nrow(x))), "d"), seq_len(nrow(x)))
      lg_info("No suitable identifier column; generated identifiers: ", ids[1], if (length(ids) > 1) paste0(" ... ", ids[length(ids)]) else "")
    }
  }

  geom <- sf::st_geometry(x)
  valid <- sf::st_is_valid(geom)
  if (any(!valid)) {
    bad <- ids[!valid]
    if (!fix_invalid) {
      stop("Invalid geometries in area(s): ", paste(bad, collapse = ", "),
           ". Fix them or set input.area.fix_invalid: true.", call. = FALSE)
    }
    lg_warn("Repairing invalid geometries with st_make_valid(): ", paste(bad, collapse = ", "))
    geom[!valid] <- sf::st_make_valid(geom[!valid])
    geom <- suppressWarnings(sf::st_collection_extract(geom, "POLYGON"))
    if (length(geom) != length(ids) || any(sf::st_is_empty(geom)) || any(!sf::st_is_valid(geom))) {
      stop("Geometry repair did not yield valid polygons for every area.", call. = FALSE)
    }
  }
  out <- sf::st_sf(area_id = ids, geometry = geom)
  out <- sf::st_transform(out, 4326)

  if (nrow(out) > 1) {
    inter <- sf::st_intersects(out, sparse = FALSE)
    diag(inter) <- FALSE
    if (any(inter)) {
      lg_warn("Some study areas overlap; records inside overlaps are counted in each overlapping area")
    }
  }
  out
}

#' Load study areas from a GPKG
#'
#' @param path Path to a single GPKG file.
#' @param layer Layer name; required when the file has more than one layer.
#' @param id_column Optional identifier column.
#' @param fix_invalid Whether to repair invalid geometries.
#' @return An `sf` object as returned by [prepare_areas()].
#' @export
load_area <- function(path, layer = NULL, id_column = NULL, fix_invalid = FALSE) {
  if (!file.exists(path)) stop("GPKG not found: ", path, call. = FALSE)
  layers <- sf::st_layers(path)$name
  if (is.null(layer)) {
    if (length(layers) != 1) {
      stop("The GPKG has ", length(layers), " layers (", paste(layers, collapse = ", "),
           "); set input.area.layer.", call. = FALSE)
    }
    layer <- layers
  } else if (!layer %in% layers) {
    stop("Layer '", layer, "' not found. Available: ", paste(layers, collapse = ", "), call. = FALSE)
  }
  lg_info("Reading GPKG: ", path, " (layer '", layer, "')")
  x <- sf::st_read(path, layer = layer, quiet = TRUE)
  prepare_areas(x, id_column = id_column, fix_invalid = fix_invalid)
}

#' Draw a single study-area polygon on an interactive map
#'
#' Requires the suggested packages `mapedit`, `leaflet` and `shiny`. The map
#' opens in the browser, so it also works from `Rscript`.
#'
#' @return An `sf` object with exactly one polygon (`area_id = "area_01"`).
#' @export
draw_area <- function() {
  for (p in c("mapedit", "leaflet", "shiny")) {
    if (!requireNamespace(p, quietly = TRUE)) {
      stop("Package '", p, "' is required for mode = \"draw\". Install it with renv::install(\"", p, "\").", call. = FALSE)
    }
  }
  lg_info("Opening interactive map: draw ONE polygon, then press 'Done'")
  map <- leaflet::addTiles(leaflet::leaflet())
  feat <- mapedit::drawFeatures(map = map, viewer = shiny::browserViewer())
  if (is.null(feat) || nrow(feat) == 0) stop("No geometry was drawn.", call. = FALSE)
  is_poly <- as.character(sf::st_geometry_type(feat)) %in% c("POLYGON", "MULTIPOLYGON")
  feat <- feat[is_poly, ]
  if (nrow(feat) != 1) stop("Exactly one polygon must be drawn (found ", nrow(feat), ").", call. = FALSE)
  sf::st_crs(feat) <- sf::st_crs(feat) # drawFeatures returns EPSG:4326
  feat$area_id <- "area_01"
  prepare_areas(feat[, "area_id"], id_column = "area_id", fix_invalid = FALSE)
}
