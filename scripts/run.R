#!/usr/bin/env Rscript
# Usage: Rscript scripts/run.R config/config.yaml

#TODO habilitar para rodar por linha de comando
args <- commandArgs(trailingOnly = TRUE)

#TODO habilitar para rodar no R
# args <- function(trailingOnly = TRUE) "config/config.yaml"

if (length(args) != 1) {
  cat("Usage: Rscript scripts/run.R <config.yaml>\n", file = stderr())
  quit(status = 2)
}
config_path <- normalizePath(args[1], mustWork = FALSE)
if (!file.exists(config_path)) {
  cat("Configuration file not found:", args[1], "\n", file = stderr())
  quit(status = 2)
}

file_arg <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))[1]
root <- normalizePath(file.path(dirname(file_arg), ".."), mustWork = TRUE)

# Activate renv when the script is not started from the project root
autoload <- !identical(tolower(Sys.getenv("RENV_CONFIG_AUTOLOADER_ENABLED")), "false")
if (autoload && file.exists(file.path(root, "renv", "activate.R")) && !nzchar(Sys.getenv("RENV_PROJECT"))) {
  setwd(root)
  source(file.path(root, "renv", "activate.R"))
}

# Load the modules into a private environment (no global state)
app <- new.env(parent = globalenv())
for (f in sort(list.files(file.path(root, "R"), pattern = "\\.R$", full.names = TRUE))) {
  sys.source(f, envir = app, keep.source = FALSE)
}
quit(status = app$run_assessment(config_path, root))
