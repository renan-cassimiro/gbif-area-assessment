# Descriptive metrics ----------------------------------------------------------

.UNASSIGNED <- "Unassigned"
.MAX_DENSITY_CELLS <- 2e5

#' Choose the projected CRS used for areas and density grids
#'
#' @param areas Study areas (`sf`, EPSG:4326).
#' @param setting `"auto"` (Lambert azimuthal equal-area centred on the areas)
#'   or any CRS accepted by [sf::st_crs()] that is projected.
#' @return An `sf` `crs` object.
#' @export
get_metric_crs <- function(areas, setting = "auto") {
  if (identical(setting, "auto")) {
    cen <- suppressWarnings(sf::st_coordinates(sf::st_centroid(sf::st_union(sf::st_geometry(areas)))))
    return(sf::st_crs(sprintf("+proj=laea +lat_0=%.4f +lon_0=%.4f +x_0=0 +y_0=0 +datum=WGS84 +units=m +no_defs",
                              cen[1, 2], cen[1, 1])))
  }
  crs <- sf::st_crs(setting)
  if (is.na(crs) || isTRUE(sf::st_is_longlat(crs))) {
    stop("analysis.metric_crs must be a valid projected CRS (got '", setting, "').", call. = FALSE)
  }
  crs
}

#' Area of each polygon in km2
#' @param areas Study areas.
#' @param metric_crs Projected CRS.
#' @return Numeric vector (km2) aligned with `areas`.
#' @export
area_km2 <- function(areas, metric_crs) {
  as.numeric(sf::st_area(sf::st_transform(areas, metric_crs))) / 1e6
}

.zero_fill <- function(df, area_ids, fill = 0) {
  full <- data.frame(area_id = area_ids, stringsAsFactors = FALSE)
  out <- merge(full, df, by = "area_id", all.x = TRUE, sort = FALSE)
  out <- out[match(area_ids, out$area_id), , drop = FALSE]
  for (nm in setdiff(names(out), "area_id")) if (is.numeric(out[[nm]])) out[[nm]][is.na(out[[nm]])] <- fill
  rownames(out) <- NULL
  out
}

#' Record counts and densities per area
#'
#' @param records_sf Processed records.
#' @param areas Study areas with an `area_km2` column.
#' @param retrieval Data frame with `area_id`, `n_total_without_filters`, `n_retrieved`.
#' @return A data frame with one row per area.
#' @export
calculate_area_metrics <- function(records_sf, areas, retrieval) {
  ids <- areas$area_id
  n_proc <- table(factor(records_sf$area_id, levels = ids))
  out <- data.frame(
    area_id = ids,
    area_km2 = areas$area_km2,
    n_total_without_filters = retrieval$n_total_without_filters[match(ids, retrieval$area_id)],
    n_retrieved = retrieval$n_retrieved[match(ids, retrieval$area_id)],
    n_processed = as.integer(n_proc[ids]),
    stringsAsFactors = FALSE
  )
  out$records_per_km2 <- out$n_processed / out$area_km2
  out
}

.top_by_area <- function(df, col, area_ids, top_n) {
  if (nrow(df) == 0) {
    return(data.frame(area_id = character(), group = character(), n_records = integer(), pct_records = numeric()))
  }
  v <- as.character(df[[col]])
  v[is.na(v) | !nzchar(v)] <- .UNASSIGNED
  tab <- as.data.frame(table(area_id = df$area_id, group = v), stringsAsFactors = FALSE)
  names(tab)[3] <- "n_records"
  tab <- tab[tab$n_records > 0, ]
  tot <- tapply(tab$n_records, tab$area_id, sum)
  tab$pct_records <- 100 * tab$n_records / tot[tab$area_id]
  tab <- tab[order(match(tab$area_id, area_ids), -tab$n_records, tab$group), ]
  tab <- do.call(rbind, lapply(split(tab, factor(tab$area_id, levels = area_ids)), utils::head, n = top_n))
  rownames(tab) <- NULL
  tab
}

#' Taxonomic richness and main groups per area
#'
#' Counts distinct non-missing `species`, `genus` and `family` values (as
#' returned by the GBIF backbone) and lists the most frequent classes,
#' families and species.
#'
#' @param records_sf Processed records.
#' @param area_ids Area identifiers (to include areas without records).
#' @param top_n Number of top groups per area.
#' @return A list with `summary`, `top_classes`, `top_families`, `top_species`.
#' @export
calculate_taxonomic_metrics <- function(records_sf, area_ids, top_n = 10L) {
  df <- sf::st_drop_geometry(records_sf)
  nd <- function(x) length(unique(x[!is.na(x) & nzchar(x)]))
  if (nrow(df) > 0) {
    s <- do.call(rbind, lapply(split(df, df$area_id), function(d) {
      data.frame(area_id = d$area_id[1], n_species = nd(d$species), n_genera = nd(d$genus),
                 n_families = nd(d$family), n_records_without_species = sum(is.na(d$species) | !nzchar(d$species)))
    }))
  } else s <- data.frame(area_id = character(), n_species = integer(), n_genera = integer(),
                         n_families = integer(), n_records_without_species = integer())
  sp <- df[!is.na(df$species) & nzchar(df$species), , drop = FALSE]
  list(
    summary = .zero_fill(s, area_ids),
    top_classes = .top_by_area(df, "class", area_ids, top_n),
    top_families = .top_by_area(df, "family", area_ids, top_n),
    top_species = .top_by_area(sp, "species", area_ids, top_n)
  )
}

#' Temporal distribution of records
#'
#' @param records_sf Processed records.
#' @param area_ids Area identifiers.
#' @return A list with `by_year` (records and species per area and year) and
#'   `summary` (year range, years with records, records without year).
#' @export
calculate_temporal_metrics <- function(records_sf, area_ids) {
  df <- sf::st_drop_geometry(records_sf)
  by_year <- data.frame(area_id = character(), year = numeric(), n_records = integer(), n_species = integer())
  if (nrow(df) > 0) {
    d <- df[is.finite(df$year), , drop = FALSE]
    if (nrow(d) > 0) {
      by_year <- do.call(rbind, lapply(split(d, list(d$area_id, d$year), drop = TRUE), function(x) {
        sp <- x$species[!is.na(x$species) & nzchar(x$species)]
        data.frame(area_id = x$area_id[1], year = x$year[1], n_records = nrow(x), n_species = length(unique(sp)))
      }))
      by_year <- by_year[order(match(by_year$area_id, area_ids), by_year$year), ]
      rownames(by_year) <- NULL
    }
  }
  summ <- do.call(rbind, lapply(area_ids, function(id) {
    y <- df$year[df$area_id == id]
    yy <- y[is.finite(y)]
    data.frame(area_id = id,
               year_min = if (length(yy)) min(yy) else NA_real_,
               year_max = if (length(yy)) max(yy) else NA_real_,
               n_years_with_records = length(unique(yy)),
               n_records_without_year = sum(!is.finite(y)))
  }))
  list(by_year = by_year, summary = summ)
}

#' Density grid and spatial coverage per area
#'
#' A square grid (side `cell_km`) is laid over each area, clipped to the
#' polygon. Each record is counted in exactly one cell. Coverage is the share
#' of cells with at least one record; concentration is the share of records in
#' the 10% most populated cells.
#'
#' @param records_sf Processed records (EPSG:4326).
#' @param areas Study areas (EPSG:4326).
#' @param metric_crs Projected CRS.
#' @param cell_km Cell side in km.
#' @return A list with `density` (`sf`, EPSG:4326) and `summary` (data frame).
#' @export
calculate_density <- function(records_sf, areas, metric_crs, cell_km) {
  cell_m <- cell_km * 1000
  areas_m <- sf::st_transform(areas, metric_crs)
  recs_m <- if (nrow(records_sf) > 0) sf::st_transform(records_sf, metric_crs) else records_sf
  dens <- list(); summ <- list()
  for (i in seq_len(nrow(areas_m))) {
    a <- areas_m[i, "area_id"]
    id <- a$area_id
    bb <- sf::st_bbox(a)
    n_est <- ceiling((bb["xmax"] - bb["xmin"]) / cell_m) * ceiling((bb["ymax"] - bb["ymin"]) / cell_m)
    if (n_est > .MAX_DENSITY_CELLS) {
      stop("Density grid for area '", id, "' would have ~", format(n_est, scientific = FALSE),
           " cells; increase analysis.density_cell_km.", call. = FALSE)
    }
    grid <- sf::st_make_grid(sf::st_geometry(a), cellsize = cell_m)
    grid <- sf::st_sf(cell_id = seq_along(grid), geometry = grid)
    grid <- grid[lengths(sf::st_intersects(grid, sf::st_geometry(a))) > 0, ]
    clipped <- suppressWarnings(sf::st_intersection(grid, a))
    clipped <- suppressWarnings(sf::st_collection_extract(clipped, "POLYGON"))
    clipped <- clipped |>
      dplyr::group_by(.data$cell_id, .data$area_id) |>
      dplyr::summarise(.groups = "drop")
    clipped$cell_area_km2 <- as.numeric(sf::st_area(clipped)) / 1e6

    n_rec <- integer(max(grid$cell_id)); n_sp <- integer(max(grid$cell_id))
    pts <- recs_m[recs_m$area_id == id, ]
    if (nrow(pts) > 0) {
      hit <- sf::st_intersects(sf::st_geometry(pts), sf::st_geometry(grid))
      cell <- vapply(hit, function(z) if (length(z)) grid$cell_id[z[1]] else NA_integer_, integer(1))
      ok <- !is.na(cell)
      n_rec <- tabulate(cell[ok], nbins = length(n_rec))
      sp <- pts$species
      keep <- ok & !is.na(sp) & nzchar(sp)
      if (any(keep)) {
        u <- unique(data.frame(cell = cell[keep], sp = sp[keep]))
        n_sp <- tabulate(u$cell, nbins = length(n_sp))
      }
    }
    clipped$n_records <- n_rec[clipped$cell_id]
    clipped$n_species <- n_sp[clipped$cell_id]
    clipped$records_per_km2 <- clipped$n_records / clipped$cell_area_km2
    dens[[id]] <- clipped

    counts <- sort(clipped$n_records, decreasing = TRUE)
    n_cells <- length(counts)
    top_k <- max(1, ceiling(0.1 * n_cells))
    summ[[id]] <- data.frame(
      area_id = id, cell_km = cell_km, n_cells = n_cells,
      n_cells_with_records = sum(counts > 0),
      coverage_pct = 100 * sum(counts > 0) / n_cells,
      top10pct_cells_share_pct = if (sum(counts) > 0) 100 * sum(counts[seq_len(top_k)]) / sum(counts) else NA_real_
    )
  }
  density <- sf::st_transform(do.call(rbind, dens), 4326)
  rownames(density) <- NULL
  list(density = density, summary = do.call(rbind, summ) |> `rownames<-`(NULL))
}

#' Descriptive comparison between areas
#'
#' Only meaningful (and only called) when there are two or more areas.
#'
#' @param area_metrics From [calculate_area_metrics()].
#' @param tax From [calculate_taxonomic_metrics()].
#' @param temporal From [calculate_temporal_metrics()].
#' @param spatial Spatial summary from [calculate_density()].
#' @param records_sf Processed records (used for shared species).
#' @return A list with `table` (one row per area) and `shared_species`
#'   (pairwise shared species and Jaccard index; descriptive only).
#' @export
calculate_comparison <- function(area_metrics, tax, temporal, spatial, records_sf) {
  tab <- Reduce(function(x, y) merge(x, y, by = "area_id", sort = FALSE),
                list(area_metrics[, c("area_id", "area_km2", "n_processed", "records_per_km2")],
                     tax$summary[, c("area_id", "n_species", "n_genera", "n_families")],
                     temporal$summary[, c("area_id", "year_min", "year_max", "n_years_with_records")],
                     spatial[, c("area_id", "coverage_pct", "top10pct_cells_share_pct")]))
  tab <- tab[match(area_metrics$area_id, tab$area_id), ]
  rownames(tab) <- NULL
  df <- sf::st_drop_geometry(records_sf)
  sets <- lapply(area_metrics$area_id, function(id) {
    s <- df$species[df$area_id == id]
    unique(s[!is.na(s) & nzchar(s)])
  })
  names(sets) <- area_metrics$area_id
  pairs <- utils::combn(area_metrics$area_id, 2, simplify = FALSE)
  shared <- do.call(rbind, lapply(pairs, function(p) {
    inter <- length(intersect(sets[[p[1]]], sets[[p[2]]]))
    uni <- length(union(sets[[p[1]]], sets[[p[2]]]))
    data.frame(area_a = p[1], area_b = p[2], n_shared_species = inter, n_union_species = uni,
               jaccard = if (uni > 0) inter / uni else NA_real_)
  }))
  list(table = tab, shared_species = shared)
}
