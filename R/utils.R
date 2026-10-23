# Utility helpers shared across modules ---------------------------------------

#' Null-coalescing operator
#' @param x,y Values; `y` is returned when `x` is `NULL`.
#' @return `x` unless it is `NULL`, otherwise `y`.
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x)) y else x

#' Resolve a path relative to the project root
#'
#' @param path Character path (absolute or relative) or `NULL`.
#' @param root Project root directory.
#' @return An absolute-or-root-relative path, or `NULL` if `path` is `NULL`.
#' @keywords internal
resolve_path <- function(path, root) {
  if (is.null(path) || length(path) == 0 || is.na(path)) return(NULL)
  if (grepl("^(/|[A-Za-z]:[/\\\\]|~)", path)) path.expand(path) else file.path(root, path)
}

#' Abort with a configuration error message
#' @param ... Message pieces pasted together.
#' @return Never returns; signals an error.
#' @keywords internal
abort_config <- function(...) stop("Configuration error: ", paste0(...), call. = FALSE)

#' Run a named pipeline step with logging and timing
#'
#' @param label Step label used in the log.
#' @param expr Expression evaluated lazily inside the step.
#' @param timings Environment in which the duration (seconds) is stored.
#' @return The value of `expr`.
#' @keywords internal
run_step <- function(label, expr, timings = NULL) {
  lg_info("Step started: ", label)
  t0 <- Sys.time()
  out <- tryCatch(expr, error = function(e) {
    lg_error("Step failed: ", label, " - ", conditionMessage(e))
    stop(e)
  })
  dt <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 2)
  if (!is.null(timings)) assign(label, dt, envir = timings)
  lg_info("Step finished: ", label, " (", dt, " s)")
  out
}

#' Create a directory if needed
#' @param path Directory path.
#' @return `path`, invisibly.
#' @keywords internal
ensure_dir <- function(path) {
  if (!dir.exists(path) && !dir.create(path, recursive = TRUE, showWarnings = FALSE)) {
    stop("Could not create directory: ", path, call. = FALSE)
  }
  invisible(path)
}

#' Read the tool version from DESCRIPTION
#' @param root Project root.
#' @return Version string, or `NA_character_`.
#' @keywords internal
get_tool_version <- function(root) {
  f <- file.path(root, "DESCRIPTION")
  if (!file.exists(f)) return(NA_character_)
  unname(read.dcf(f, fields = "Version")[1, 1])
}

#' Git information for the project
#' @param root Project root.
#' @return List with `available`, `commit`, `branch`, `dirty`.
#' @keywords internal
git_info <- function(root) {
  empty <- list(available = FALSE, commit = NA_character_, branch = NA_character_, dirty = NA)
  if (!nzchar(Sys.which("git"))) return(empty)
  g <- function(...) {
    tryCatch(suppressWarnings(system2("git", c("-C", shQuote(root), ...), stdout = TRUE, stderr = FALSE)),
             error = function(e) character())
  }
  commit <- g("rev-parse", "--short", "HEAD")
  if (length(commit) == 0 || !is.null(attr(commit, "status"))) return(empty)
  branch <- g("rev-parse", "--abbrev-ref", "HEAD")
  status <- g("status", "--porcelain")
  list(available = TRUE, commit = commit[1], branch = branch[1] %||% NA_character_,
       dirty = length(status) > 0)
}

#' renv and session information for the report
#' @param root Project root.
#' @return List describing R, platform, renv state and key package versions.
#' @keywords internal
environment_info <- function(root) {
  lock <- file.path(root, "renv.lock")
  proj <- Sys.getenv("RENV_PROJECT", unset = "")
  active <- nzchar(proj) && identical(normalizePath(proj, mustWork = FALSE),
                                      normalizePath(root, mustWork = FALSE))
  pkgs <- c("rgbif", "sf", "dplyr", "tidyr", "ggplot2", "logger", "yaml", "terra", "rmarkdown", "knitr")
  versions <- vapply(pkgs, function(p) {
    tryCatch(as.character(utils::packageVersion(p)), error = function(e) NA_character_)
  }, character(1))
  list(
    r_version = R.version.string,
    platform = R.version$platform,
    renv_active = active,
    renv_lock_present = file.exists(lock),
    renv_lock_md5 = if (file.exists(lock)) unname(tools::md5sum(lock)) else NA_character_,
    package_versions = as.list(versions)
  )
}
