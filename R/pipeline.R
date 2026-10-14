# Pipeline orchestration -------------------------------------------------------

#' Run the full GBIF area assessment
#'
#' Entry point used by `scripts/run.R`. Errors are logged and turned into a
#' non-zero status; a `run_status.yaml` file records whether the run completed.
#'
#' @param config_path Absolute path to the YAML configuration.
#' @param root Project root directory.
#' @return `0L` on success, `1L` on failure (integer exit status).
#' @export
run_assessment <- function(config_path, root) {
  collector <- setup_logging("INFO")
  state <- new.env(parent = emptyenv())
  ok <- tryCatch({
    withCallingHandlers(
      .run_pipeline(config_path, root, collector, state),
      warning = function(w) {
        lg_warn("R warning: ", conditionMessage(w))
        invokeRestart("muffleWarning")
      }
    )
    TRUE
  }, error = function(e) {
    lg_error(conditionMessage(e))
    lg_error("Analysis aborted; no final report was produced.")
    if (!is.null(state$run_dir)) {
      try(yaml::write_yaml(list(status = "failed", error = conditionMessage(e),
                                finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
                           file.path(state$run_dir, "run_status.yaml")), silent = TRUE)
    }
    FALSE
  })
  if (ok) 0L else 1L
}

.run_pipeline <- function(config_path, root, collector, state) {
  started <- Sys.time()
  timings <- new.env(parent = emptyenv())
  lg_info("Starting GBIF area assessment")

  # configuration ---------------------------------------------------------------
  raw_cfg <- run_step("read configuration", read_config(config_path), timings)
  cfg <- run_step("validate configuration", validate_config(raw_cfg, root), timings)
  set_log_level(cfg$logging$level)

  run_id <- format(started, "%Y%m%d_%H%M%S")
  run_dir <- file.path(cfg$paths$output, paste0("run_", run_id))
  if (dir.exists(run_dir)) stop("Run directory already exists: ", run_dir, call. = FALSE)
  for (d in c("figures", "spatial", "tables", "logs", "report")) ensure_dir(file.path(run_dir, d))
  state$run_dir <- run_dir
  add_log_file(file.path(run_dir, "logs", paste0("run_", run_id, ".log")))
  file.copy(config_path, file.path(run_dir, "config_original.yaml"))
  cfg_eff <- cfg; cfg_eff$gbif$filters_normalized <- NULL
  yaml::write_yaml(cfg_eff[names(cfg_eff) != "paths"], file.path(run_dir, "config_effective.yaml"))
  lg_info("Run directory: ", run_dir)
  lg_info("Configuration file: ", config_path)

  tool_version <- get_tool_version(root)
  env <- environment_info(root)
  if (!env$renv_active) lg_warn("renv is not active for this project; the run may not be reproducible")
  lg_info("Project: ", cfg$project$name, " | tool ", tool_version, " | ", env$r_version)

  # areas -----------------------------------------------------------------------
  a <- cfg$input$area
  lg_info("Input mode: ", a$mode)
  areas <- run_step("load study areas", {
    if (a$mode == "gpkg") {
      load_area(cfg$paths$area, a$layer, a$id_column, a$fix_invalid)
    } else {
      x <- draw_area()
      sf::st_write(x, file.path(run_dir, "spatial", "drawn_area.gpkg"), quiet = TRUE)
      lg_info("Drawn polygon saved to results (spatial/drawn_area.gpkg) for reproduction")
      x
    }
  }, timings)
  metric_crs <- get_metric_crs(areas, cfg$analysis$metric_crs)
  areas$area_km2 <- area_km2(areas, metric_crs)
  lg_info("Number of study areas: ", nrow(areas))
  for (i in seq_len(nrow(areas))) lg_info("  ", areas$area_id[i], ": ", round(areas$area_km2[i], 2), " km2")
  if (nrow(areas) == 1) lg_info("Single area: individual analysis only") else lg_info("Multiple areas: individual analyses + comparison")

  # GBIF ------------------------------------------------------------------------
  filters <- cfg$gbif$filters_normalized
  lg_info("GBIF query method: ", cfg$gbif$query$method)
  if (length(filters)) {
    for (nm in names(filters)) lg_info("GBIF filter ", nm, " = ", paste(filters[[nm]], collapse = ", "))
  } else lg_info("No GBIF filters configured (spatial restriction only)")

  results <- list()
  for (i in seq_len(nrow(areas))) {
    id <- areas$area_id[i]
    results[[id]] <- run_step(paste0("GBIF records: ", id), {
      q <- build_gbif_query(id, sf::st_geometry(areas[i, ]), filters, cfg$gbif$query)
      get_gbif_records(q, cfg$gbif$cache, cfg$paths$cache, tool_version)
    }, timings)
  }
  retrieval <- do.call(rbind, lapply(names(results), function(id) {
    r <- results[[id]]
    data.frame(area_id = id, source = r$source, cache_key = r$cache_key,
               queried_at = as.character(r$meta$queried_at),
               n_total_without_filters = as.numeric(r$meta$n_total_without_filters %||% NA),
               n_retrieved = NROW(r$records), method = r$meta$method %||% "search",
               download_doi = as.character(r$meta$download_doi %||% NA), stringsAsFactors = FALSE)
  }))
  lg_info("Records retrieved in total: ", sum(retrieval$n_retrieved))
  if (sum(retrieval$n_retrieved) == 0) lg_warn("No GBIF records were found for any study area; empty results will be produced")

  # processing --------------------------------------------------------------------
  proc <- run_step("process records", {
    combined <- combine_area_records(stats::setNames(lapply(results, `[[`, "records"), names(results)))
    v <- validate_records(combined)
    sfr <- records_to_sf(v$records)
    asg <- assign_records_to_areas(sfr, areas, verify = identical(cfg$gbif$query$method, "search"))
    list(records = asg$records, removed = rbind(v$removed, asg$removed))
  }, timings)
  records_sf <- proc$records
  lg_info("Records after processing: ", nrow(records_sf))

  # metrics -----------------------------------------------------------------------
  metrics <- run_step("calculate metrics", {
    ids <- areas$area_id
    area_m <- calculate_area_metrics(records_sf, areas, retrieval)
    tax <- calculate_taxonomic_metrics(records_sf, ids, cfg$analysis$top_n)
    temporal <- calculate_temporal_metrics(records_sf, ids)
    dens <- calculate_density(records_sf, areas, metric_crs, cfg$analysis$density_cell_km)
    list(area = area_m, taxonomic = tax, temporal = temporal, spatial = dens$summary, density = dens$density)
  }, timings)
  comparison <- NULL
  if (nrow(areas) >= 2) {
    comparison <- run_step("compare areas", calculate_comparison(metrics$area, metrics$taxonomic,
                                                                 metrics$temporal, metrics$spatial, records_sf), timings)
  }

  # outputs -----------------------------------------------------------------------
  run_step("write spatial layers", {
    layers <- create_spatial_layers(areas, records_sf, metrics$density, cfg$output$write_records_layer)
    write_spatial_layers(layers, file.path(run_dir, "spatial", "gbif_area_assessment.gpkg"))
  }, timings)
  tables <- c(list(retrieval = retrieval, removed_records = proc$removed,
                   area_summary = metrics$area, taxonomic = metrics$taxonomic,
                   temporal = metrics$temporal, spatial_summary = metrics$spatial),
              if (!is.null(comparison)) list(comparison = comparison))
  run_step("write tables", write_output_tables(tables, file.path(run_dir, "tables")), timings)

  figs <- run_step("create figures", {
    fd <- file.path(run_dir, "figures")
    f <- list()
    f$areas_map <- save_plot(plot_areas(areas), file.path(fd, "map_areas.png"))
    rm_ <- plot_records(areas, records_sf, cfg$analysis$max_map_points); dm_ <- plot_density(metrics$density, areas)
    nm <- .safe_name(areas$area_id)
    f$records_maps <- stats::setNames(lapply(seq_along(rm_), function(i) save_plot(rm_[[i]], file.path(fd, paste0("map_records_", nm[i], ".png")))), areas$area_id)
    f$density_maps <- stats::setNames(lapply(seq_along(dm_), function(i) save_plot(dm_[[i]], file.path(fd, paste0("map_density_", nm[i], ".png")))), areas$area_id)
    f$temporal <- save_plot(plot_temporal_distribution(metrics$temporal$by_year), file.path(fd, "temporal_distribution.png"),
                            width = max(7, 2.5 * nrow(areas) + 2))
    f$records_by_area <- save_plot(plot_records_by_area(metrics$area), file.path(fd, "records_by_area.png"))
    f$species_by_area <- save_plot(plot_species_by_area(metrics$taxonomic$summary), file.path(fd, "species_by_area.png"))
    f$taxon_groups <- save_plot(plot_taxon_groups(metrics$taxonomic$top_classes), file.path(fd, "taxon_groups.png"),
                                width = max(7, 3 * min(nrow(areas), 3)), height = 5)
    if (!is.null(comparison)) f$comparison <- save_plot(plot_area_comparison(comparison$table), file.path(fd, "area_comparison.png"), width = 9, height = 6)
    f
  }, timings)

  # report ------------------------------------------------------------------------
  filters_table <- data.frame(filter = names(filters),
                              value = vapply(filters, function(v) paste(v, collapse = ", "), ""),
                              stringsAsFactors = FALSE)
  ctx <- list(
    project = cfg$project$name, run_id = run_id, run_dir = run_dir, config_path = config_path,
    generated_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z"),
    tool_version = tool_version, git = git_info(root), environment = env,
    config = cfg, config_effective = cfg_eff, input_mode = a$mode,
    areas = sf::st_drop_geometry(areas), filters_table = filters_table,
    retrieval = retrieval, removed = proc$removed,
    metrics = metrics[setdiff(names(metrics), "density")], comparison = comparison,
    figures = figs, warnings = collector$store$msgs, timings = as.list(timings)
  )
  ctx$limitations <- build_limitations(ctx)
  ctx_file <- file.path(run_dir, "tables", "run_context.rds")
  saveRDS(ctx, ctx_file)
  run_step("render PDF report", render_report(ctx_file, file.path(root, "report", "report_template.Rmd"),
                                              file.path(run_dir, "report", "gbif_area_assessment.pdf")), timings)

  dur <- round(as.numeric(difftime(Sys.time(), started, units = "secs")), 1)
  yaml::write_yaml(list(status = "completed", run_id = run_id, duration_seconds = dur,
                        finished_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z")),
                   file.path(run_dir, "run_status.yaml"))
  lg_info("Analysis completed successfully (", dur, " s). Results: ", run_dir)
  invisible(TRUE)
}
