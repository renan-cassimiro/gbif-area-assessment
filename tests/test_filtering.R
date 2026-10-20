#!/usr/bin/env Rscript
# Deterministic smoke tests for the raster-filter core; no live GBIF calls.
args <- commandArgs(trailingOnly = TRUE)
root <- if (length(args)) normalizePath(args[1], mustWork = TRUE) else normalizePath(".", mustWork = TRUE)
if (!requireNamespace("terra", quietly = TRUE)) stop("Package 'terra' is required for this test.")
if (!requireNamespace("sf", quietly = TRUE)) stop("Package 'sf' is required for this test.")
app <- new.env(parent = globalenv())
for (f in sort(list.files(file.path(root, "R"), pattern = "\\.R$", full.names = TRUE))) {
  sys.source(f, envir = app, keep.source = FALSE)
}
tmp <- tempfile("gbif-filter-test-"); dir.create(tmp)
r_path <- file.path(tmp, "known_values.tif")
r <- terra::rast(nrows = 2, ncols = 2, xmin = 0, xmax = 2, ymin = 0, ymax = 2, crs = "EPSG:4326")
terra::values(r) <- c(1, 2, NA, 3)
terra::writeRaster(r, r_path, overwrite = TRUE)
records <- data.frame(
  gbifID = as.character(1:5),
  decimalLongitude = c(0.5, 1.5, 0.5, 1.5, 3),
  decimalLatitude = c(1.5, 1.5, 0.5, 0.5, 1),
  area_id = rep("test_area", 5),
  species = paste0("Species ", 1:5),
  year = rep(2020, 5),
  stringsAsFactors = FALSE
)
out <- app$apply_raster_occurrence_filter(records, r_path, c(1, 3))
stopifnot(nrow(out$records) == 2L)
stopifnot(setequal(out$records$gbifID, c("1", "4")))
stopifnot(sum(out$removed$n) == 3L)
stopifnot(setequal(out$removed$reason, c("raster value not accepted", "raster NoData / unavailable value", "outside raster extent")))

bad_path <- file.path(tmp, "wrong_crs.tif")
r_bad <- terra::rast(nrows = 2, ncols = 2, xmin = 0, xmax = 2, ymin = 0, ymax = 2, crs = "EPSG:3857")
terra::values(r_bad) <- c(1, 2, 3, 4)
terra::writeRaster(r_bad, bad_path, overwrite = TRUE)
err <- tryCatch({ app$apply_raster_occurrence_filter(records, bad_path, c(1, 3)); NULL }, error = identity)
stopifnot(inherits(err, "error"), grepl("EPSG:4326", conditionMessage(err), fixed = TRUE))

# Cache entry reads are read-only and validate the existing cache schema.
cache_key <- "synthetic-cache-key"
cache_dir <- file.path(tmp, cache_key)
dir.create(cache_dir)
cache_records <- records
saveRDS(cache_records, file.path(cache_dir, "records.rds"))
yaml::write_yaml(list(cache_key=cache_key, cache_schema=1L, area_id="test_area", n_records=nrow(cache_records),
                      queried_at="2026-01-01T00:00:00Z", geometry_wkt=NULL), file.path(cache_dir, "meta.yaml"))
records_hash_before <- unname(tools::md5sum(file.path(cache_dir, "records.rds")))
meta_hash_before <- unname(tools::md5sum(file.path(cache_dir, "meta.yaml")))
loaded <- app$.filter_read_cache_entry(cache_dir, root)
stopifnot(nrow(loaded$records) == nrow(cache_records))
stopifnot(identical(records_hash_before, unname(tools::md5sum(file.path(cache_dir, "records.rds")))))
stopifnot(identical(meta_hash_before, unname(tools::md5sum(file.path(cache_dir, "meta.yaml")))))
unlink(tmp, recursive = TRUE)
cat("Raster-filter smoke tests passed.\n")
