# PDF report -------------------------------------------------------------------

#' Objective list of limitations for the report
#'
#' @param ctx Run context list (see `run_assessment()`).
#' @return A character vector of limitation statements (no ecological interpretation).
#' @export
build_limitations <- function(ctx) {
  out <- character()
  f <- ctx$filters_table
  out <- c(out, if (nrow(f) > 0) {
    paste0("Applied GBIF filters: ", paste0(f$filter, " = ", f$value, collapse = "; "), ".")
  } else "No GBIF filters were applied (only the spatial restriction).")
  rem <- ctx$removed
  if (nrow(rem) > 0) {
    out <- c(out, paste0("Records excluded during processing: ",
                         paste0(rem$n, " (", rem$reason, ", ", rem$area_id, ")", collapse = "; "), "."))
  } else out <- c(out, "No records were excluded during technical processing.")
  am <- ctx$metrics$area
  empty <- am$area_id[am$n_processed == 0]
  if (length(empty)) out <- c(out, paste0("No records available in: ", paste(empty, collapse = ", "), "."))
  sp <- ctx$metrics$spatial
  low <- sp$area_id[sp$n_cells_with_records > 0 & sp$coverage_pct < ctx$config$analysis$low_coverage_pct]
  if (length(low)) {
    out <- c(out, paste0("Low spatial coverage (< ", ctx$config$analysis$low_coverage_pct,
                         "% of ", ctx$config$analysis$density_cell_km, " km cells with records) in: ",
                         paste(low, collapse = ", "), "."))
  }
  c(out,
    "Record counts reflect data availability in GBIF, not sampling effort or true biodiversity; no bias correction, rarefaction or inference was performed.",
    "Species, genus and family counts use the GBIF backbone fields; records identified only at higher ranks do not contribute to them.",
    "Each area is queried separately; records inside overlapping areas are counted in every overlapping area.",
    "Results are a snapshot of GBIF at the query date shown above; re-querying later may return different data.")
}

#' Render the PDF report
#'
#' @param context_file Path to the serialised run context (`.rds`).
#' @param template Path to the R Markdown template.
#' @param output_file Output PDF path.
#' @return `output_file`, invisibly.
#' @export
render_report <- function(context_file, template, output_file) {
  if (!rmarkdown::pandoc_available()) stop("pandoc is required to render the PDF report.", call. = FALSE)
  engines <- Sys.which(c("xelatex", "pdflatex", "lualatex"))
  engines <- engines[nzchar(engines)]
  if (length(engines) == 0) {
    stop("No LaTeX engine found (xelatex/pdflatex/lualatex). Install one, e.g. tinytex::install_tinytex().", call. = FALSE)
  }
  ensure_dir(dirname(output_file))
  ctx <- readRDS(context_file)
  scratch <- tempfile("report_")
  ensure_dir(file.path(scratch, "figures"))
  figs <- list.files(file.path(ctx$run_dir, "figures"), full.names = TRUE)
  file.copy(figs, file.path(scratch, "figures"))
  stem <- tools::file_path_sans_ext(basename(output_file))
  # Knit to .tex and compile it ourselves inside `scratch`, where the figures live
  # (relative paths only; no dependence on how rmarkdown picks the LaTeX working dir).
  rmarkdown::render(
    input = template,
    output_format = rmarkdown::latex_document(toc = TRUE, number_sections = TRUE),
    output_file = paste0(stem, ".tex"),
    output_dir = scratch,
    intermediates_dir = scratch,
    knit_root_dir = scratch,
    params = list(context_file = normalizePath(context_file, winslash = "/")),
    envir = new.env(parent = globalenv()),
    quiet = TRUE
  )
  compile_latex(file.path(scratch, paste0(stem, ".tex")), names(engines)[1])
  built <- file.path(scratch, paste0(stem, ".pdf"))
  if (!file.exists(built) || !file.copy(built, output_file, overwrite = TRUE)) {
    stop("PDF report was not produced in ", scratch, call. = FALSE)
  }
  unlink(scratch, recursive = TRUE)
  invisible(output_file)
}

#' Compile a .tex file (two passes, for the table of contents)
#'
#' @param tex Path to the .tex file.
#' @param engine LaTeX engine executable name.
#' @return The PDF path, invisibly. Errors with the LaTeX error lines on failure.
#' @keywords internal
compile_latex <- function(tex, engine) {
  old <- setwd(dirname(tex)); on.exit(setwd(old), add = TRUE)
  for (pass in 1:2) {
    out <- suppressWarnings(system2(engine, c("-interaction=nonstopmode", "-halt-on-error", basename(tex)),
                                    stdout = TRUE, stderr = TRUE))
    status <- attr(out, "status") %||% 0L
    if (status != 0L) {
      err <- grep("^!|^l\\.[0-9]+|not found", out, value = TRUE)
      stop("LaTeX (", engine, ") failed on pass ", pass, ":\n", paste(utils::head(err, 12), collapse = "\n"),
           "\nIntermediate files: ", dirname(tex), call. = FALSE)
    }
  }
  invisible(sub("\\.tex$", ".pdf", tex))
}
