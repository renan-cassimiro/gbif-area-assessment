#!/usr/bin/env Rscript
# Usage: Rscript scripts/filter.R config/filter.yaml
args <- commandArgs(trailingOnly=TRUE)
if(length(args)!=1L) { cat("Usage: Rscript scripts/filter.R <filter_config.yaml>\n",file=stderr()); quit(status=2L) }
config_path <- normalizePath(args[1],mustWork=FALSE)
if(!file.exists(config_path)) { cat("Configuration file not found: ",args[1],"\n",sep="",file=stderr()); quit(status=2L) }
file_arg <- sub("^--file=","",grep("^--file=",commandArgs(FALSE),value=TRUE)[1])
root <- normalizePath(file.path(dirname(file_arg),".."),mustWork=TRUE)
if(!grepl("^(/|[A-Za-z]:[/\\\\]|~)",config_path)) config_path <- file.path(getwd(),config_path)
config_path <- normalizePath(config_path,mustWork=TRUE)
autoload <- !identical(tolower(Sys.getenv("RENV_CONFIG_AUTOLOADER_ENABLED")),"false")
if(autoload && file.exists(file.path(root,"renv","activate.R")) && !nzchar(Sys.getenv("RENV_PROJECT"))) { setwd(root); source(file.path(root,"renv","activate.R")) }
setwd(root); app <- new.env(parent=globalenv())
for(f in sort(list.files(file.path(root,"R"),pattern="\\.R$",full.names=TRUE))) sys.source(f,envir=app,keep.source=FALSE)
quit(status=app$run_filtering(config_path,root))
