# Plots (ggplot2 + sf) ---------------------------------------------------------

.theme <- function() ggplot2::theme_minimal(base_size = 10)

.safe_name <- function(ids) make.unique(gsub("[^A-Za-z0-9_-]+", "_", ids), sep = "_")

#' Map of the study areas
#' @param areas Study areas (`sf`).
#' @return A ggplot.
#' @export
plot_areas <- function(areas) {
  ggplot2::ggplot(areas) +
    ggplot2::geom_sf(ggplot2::aes(fill = .data$area_id), alpha = 0.5, colour = "grey20") +
    ggplot2::geom_sf_text(ggplot2::aes(label = .data$area_id), size = 3, check_overlap = TRUE) +
    ggplot2::labs(title = "Study areas", fill = "Area") + .theme()
}

#' Maps of GBIF records, one per area
#' @param areas Study areas.
#' @param records_sf Processed records.
#' @param max_points Maximum points drawn per map (systematic sample above this).
#' @param label Title prefix.
#' @return A named list of ggplots (names = area ids); `NULL` entries for areas without records.
#' @export
plot_records <- function(areas, records_sf, max_points = 50000L, label = "GBIF records") {
  stats::setNames(lapply(areas$area_id, function(id) {
    r <- records_sf[records_sf$area_id == id, ]
    if (nrow(r) == 0) return(NULL)
    n_all <- nrow(r)
    if (n_all > max_points) {
      r <- r[unique(round(seq(1, n_all, length.out = max_points))), ]
      lg_info("Map of '", id, "' shows a systematic sample of ", nrow(r), " of ", n_all, " records")
    }
    ggplot2::ggplot() +
      ggplot2::geom_sf(data = areas[areas$area_id == id, ], fill = NA, colour = "grey20") +
      ggplot2::geom_sf(data = r, size = 0.3, alpha = 0.4, colour = "#1b6ca8") +
      ggplot2::labs(title = paste0(label, ": ", id), subtitle = if (n_all > nrow(r)) paste0(nrow(r), " of ", n_all, " records (systematic sample)") else paste(n_all, "records")) + .theme()
  }), areas$area_id)
}

#' Density maps (records per km2 per grid cell), one per area
#' @param density Density layer from [calculate_density()].
#' @param areas Study areas.
#' @param label Title prefix.
#' @return A named list of ggplots (`NULL` when the area has no records).
#' @export
plot_density <- function(density, areas, label = "Record density") {
  stats::setNames(lapply(areas$area_id, function(id) {
    d <- density[density$area_id == id, ]
    if (nrow(d) == 0 || sum(d$n_records) == 0) return(NULL)
    ggplot2::ggplot() +
      ggplot2::geom_sf(data = d, ggplot2::aes(fill = .data$records_per_km2), colour = NA) +
      ggplot2::geom_sf(data = areas[areas$area_id == id, ], fill = NA, colour = "grey20") +
      ggplot2::scale_fill_viridis_c(option = "magma", direction = -1, trans = "sqrt", name = "records/km\u00b2") +
      ggplot2::labs(title = paste0(label, ": ", id)) + .theme()
  }), areas$area_id)
}

#' Records and species per year
#' @param by_year Table from [calculate_temporal_metrics()].
#' @return A ggplot, or `NULL` without data.
#' @export
plot_temporal_distribution <- function(by_year) {
  if (nrow(by_year) == 0) return(NULL)
  long <- tidyr::pivot_longer(by_year, c("n_records", "n_species"), names_to = "metric", values_to = "value")
  long$metric <- factor(long$metric, c("n_records", "n_species"), c("Records", "Species"))
  ggplot2::ggplot(long, ggplot2::aes(.data$year, .data$value)) +
    ggplot2::geom_col(fill = "#1b6ca8") +
    ggplot2::facet_grid(metric ~ area_id, scales = "free_y") +
    ggplot2::labs(x = "Year", y = NULL, title = "Temporal distribution") + .theme()
}

.bar_by_area <- function(df, col, ylab, title) {
  ggplot2::ggplot(df, ggplot2::aes(.data$area_id, .data[[col]])) +
    ggplot2::geom_col(fill = "#1b6ca8") +
    ggplot2::labs(x = NULL, y = ylab, title = title) + .theme()
}

#' Records per area
#' @param area_metrics From [calculate_area_metrics()].
#' @return A ggplot.
#' @export
plot_records_by_area <- function(area_metrics) .bar_by_area(area_metrics, "n_processed", "Records", "Records per area")

#' Species per area
#' @param tax_summary `summary` element of [calculate_taxonomic_metrics()].
#' @return A ggplot.
#' @export
plot_species_by_area <- function(tax_summary) .bar_by_area(tax_summary, "n_species", "Species", "Species per area")

#' Main taxonomic groups
#' @param top_classes `top_classes` element of [calculate_taxonomic_metrics()].
#' @return A ggplot, or `NULL` without data.
#' @export
plot_taxon_groups <- function(top_classes) {
  if (nrow(top_classes) == 0) return(NULL)
  ggplot2::ggplot(top_classes, ggplot2::aes(stats::reorder(.data$group, .data$n_records), .data$n_records)) +
    ggplot2::geom_col(fill = "#1b6ca8") + ggplot2::coord_flip() +
    ggplot2::facet_wrap(~area_id, scales = "free") +
    ggplot2::labs(x = NULL, y = "Records", title = "Main taxonomic groups (class)") + .theme()
}

#' Descriptive comparison of areas
#' @param comparison_table `table` element of [calculate_comparison()].
#' @return A ggplot.
#' @export
plot_area_comparison <- function(comparison_table) {
  cols <- c("n_processed", "records_per_km2", "n_species", "n_genera", "n_families", "coverage_pct")
  labs <- c("Records", "Records per km\u00b2", "Species", "Genera", "Families", "Spatial coverage (%)")
  long <- tidyr::pivot_longer(comparison_table[, c("area_id", cols)], dplyr::all_of(cols),
                              names_to = "metric", values_to = "value")
  long$metric <- factor(long$metric, cols, labs)
  ggplot2::ggplot(long, ggplot2::aes(.data$area_id, .data$value)) +
    ggplot2::geom_col(fill = "#1b6ca8") +
    ggplot2::facet_wrap(~metric, scales = "free_y") +
    ggplot2::labs(x = NULL, y = NULL, title = "Comparison between areas") + .theme()
}

#' Save a plot as PNG
#' @param p A ggplot (or `NULL`, which is skipped).
#' @param file Output file.
#' @param width,height Size in inches.
#' @return `file` if written, otherwise `NA_character_`.
#' @export
save_plot <- function(p, file, width = 7, height = 5) {
  if (is.null(p)) return(NA_character_)
  withCallingHandlers(
    ggplot2::ggsave(file, p, width = width, height = height, dpi = 150, bg = "white"),
    warning = function(w) {
      # label placement on lon/lat polygons is cosmetic; keep other warnings visible
      if (grepl("st_point_on_surface", conditionMessage(w), fixed = TRUE)) invokeRestart("muffleWarning")
    })
  lg_debug("Figure saved: ", file)
  file
}
