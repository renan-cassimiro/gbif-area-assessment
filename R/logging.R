# Structured logging (logger) --------------------------------------------------

.log_levels <- c("DEBUG", "INFO", "WARN", "ERROR")

#' Normalise a log level name
#' @param level Character level (`DEBUG`, `INFO`, `WARN`/`WARNING`, `ERROR`).
#' @return One of `.log_levels`.
#' @keywords internal
normalise_log_level <- function(level) {
  lv <- toupper(as.character(level)[1])
  if (identical(lv, "WARNING")) lv <- "WARN"
  if (is.na(lv) || !lv %in% .log_levels) {
    abort_config("logging.level must be one of: ", paste(.log_levels, collapse = ", "))
  }
  lv
}

#' Configure console logging and the in-memory WARN/ERROR collector
#'
#' Index 1 writes to the console (and, later, to a file); index 2 collects
#' warnings and errors so that they can be listed in the report.
#'
#' @param level Log level.
#' @return A list with `store`, an environment whose `msgs` element holds the
#'   collected WARN/ERROR messages.
#' @export
setup_logging <- function(level = "INFO") {
  lv <- normalise_log_level(level)
  layout <- logger::layout_glue_generator(
    format = "{level} [{format(time, '%Y-%m-%d %H:%M:%S')}] {msg}"
  )
  logger::log_layout(layout, index = 1)
  logger::log_threshold(getExportedValue("logger", lv), index = 1)
  logger::log_appender(logger::appender_console, index = 1)

  store <- new.env(parent = emptyenv())
  store$msgs <- character()
  collector <- function(lines) {
    keep <- grep("^(WARN|ERROR)", lines, value = TRUE)
    if (length(keep)) store$msgs <- c(store$msgs, keep)
    invisible(NULL)
  }
  logger::log_layout(logger::layout_glue_generator(format = "{level}: {msg}"), index = 2)
  logger::log_threshold(logger::WARN, index = 2)
  logger::log_appender(collector, index = 2)
  list(store = store)
}

#' Change the console/file log level
#' @param level Log level.
#' @return `NULL`, invisibly.
#' @export
set_log_level <- function(level) {
  logger::log_threshold(getExportedValue("logger", normalise_log_level(level)), index = 1)
  invisible(NULL)
}

#' Also write log lines to a file
#' @param file Path to the log file (parent directory is created).
#' @return `file`, invisibly.
#' @export
add_log_file <- function(file) {
  ensure_dir(dirname(file))
  if (!file.exists(file)) file.create(file)
  logger::log_appender(logger::appender_tee(file), index = 1)
  invisible(file)
}

.log <- function(fun, ...) {
  msg <- paste0(...)
  fun("{msg}", namespace = "global")
}

#' Logging wrappers
#' @param ... Message pieces pasted together.
#' @return `NULL`, invisibly.
#' @name lg
#' @keywords internal
NULL

#' @rdname lg
lg_debug <- function(...) invisible(.log(logger::log_debug, ...))
#' @rdname lg
lg_info <- function(...) invisible(.log(logger::log_info, ...))
#' @rdname lg
lg_warn <- function(...) invisible(.log(logger::log_warn, ...))
#' @rdname lg
lg_error <- function(...) invisible(.log(logger::log_error, ...))
