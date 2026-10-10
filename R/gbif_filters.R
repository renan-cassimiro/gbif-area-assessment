# GBIF filters: registry, validation and translation ---------------------------

.gbif_enums <- list(
  basisOfRecord = c("FOSSIL_SPECIMEN", "HUMAN_OBSERVATION", "LITERATURE", "LIVING_SPECIMEN",
                    "MACHINE_OBSERVATION", "MATERIAL_CITATION", "MATERIAL_SAMPLE", "OBSERVATION",
                    "OCCURRENCE", "PRESERVED_SPECIMEN", "UNKNOWN"),
  occurrenceStatus = c("PRESENT", "ABSENT"),
  continent = c("AFRICA", "ANTARCTICA", "ASIA", "EUROPE", "NORTH_AMERICA", "OCEANIA", "SOUTH_AMERICA"),
  mediaType = c("StillImage", "MovingImage", "Sound"),
  license = c("CC0_1_0", "CC_BY_4_0", "CC_BY_NC_4_0", "UNSPECIFIED", "UNSUPPORTED")
)

#' Typed registry of well-known GBIF occurrence filters
#'
#' Filters not listed here are still accepted when they are arguments of
#' [rgbif::occ_data()] (generic validation).
#'
#' @return A named list of filter specifications (`type`, optional `values`).
#' @keywords internal
gbif_filter_registry <- function() {
  reg <- list()
  for (nm in names(.gbif_enums)) reg[[nm]] <- list(type = "enum", values = .gbif_enums[[nm]])
  for (nm in c("hasCoordinate", "hasGeospatialIssue", "repatriated", "isInCluster")) reg[[nm]] <- list(type = "logical")
  for (nm in c("taxonKey", "acceptedTaxonKey", "kingdomKey", "phylumKey", "classKey", "orderKey",
               "familyKey", "genusKey", "subgenusKey", "speciesKey")) reg[[nm]] <- list(type = "integer")
  for (nm in c("country", "publishingCountry")) reg[[nm]] <- list(type = "country")
  for (nm in c("year", "month")) reg[[nm]] <- list(type = "range", kind = "int")
  for (nm in c("decimalLatitude", "decimalLongitude", "elevation", "depth",
               "coordinateUncertaintyInMeters")) reg[[nm]] <- list(type = "range", kind = "num")
  for (nm in c("eventDate", "lastInterpreted")) reg[[nm]] <- list(type = "range", kind = "date")
  for (nm in c("scientificName", "datasetKey", "typeStatus", "recordNumber", "recordedBy",
               "institutionCode", "collectionCode", "catalogNumber", "stateProvince", "waterBody",
               "locality", "issue", "establishmentMeans", "protocol", "publishingOrg", "gadmGid")) {
    reg[[nm]] <- list(type = "character")
  }
  reg
}

# Arguments of occ_data() that are technical (query mechanics), not filters.
.gbif_reserved_args <- function() {
  fm <- names(formals(rgbif::occ_data))
  c("x", "geometry", "geom_big", "geom_size", "geom_n", "limit", "start", "curlopts",
    "skip_validate", "spellCheck", "hl", "return", "facet", "facetMincount",
    "facetMultiselect", "facetLimit", "facetOffset",
    fm[grepl("^facet", fm)])
}

.as_chr <- function(nm, val) {
  v <- unlist(val, use.names = FALSE)
  if (is.null(v) || length(v) == 0 || anyNA(v)) abort_config("filter '", nm, "' has empty or NA values")
  as.character(v)
}

.normalize_range <- function(nm, val, kind) {
  parse1 <- function(x) {
    if (is.null(x) || length(x) != 1 || is.na(x)) {
      abort_config("filter '", nm, "' requires both min and max (rgbif range queries need both bounds)")
    }
    x <- trimws(as.character(x))
    ok <- switch(kind,
                 int = grepl("^-?[0-9]+$", x),
                 num = grepl("^-?[0-9]+(\\.[0-9]+)?$", x),
                 date = grepl("^[0-9]{4}(-[0-9]{2}(-[0-9]{2})?)?$", x))
    if (!ok) abort_config("filter '", nm, "' has an invalid value: ", x)
    x
  }
  if (is.list(val)) {
    if (is.null(names(val)) || length(setdiff(names(val), c("min", "max"))) > 0) {
      abort_config("filter '", nm, "' must use only 'min' and 'max' keys")
    }
    lo <- parse1(val[["min"]]); hi <- parse1(val[["max"]])
  } else {
    if (length(val) != 1) abort_config("filter '", nm, "' must be a single value, 'a,b' string or {min, max}")
    s <- as.character(val)
    if (grepl(",", s, fixed = TRUE)) {
      p <- trimws(strsplit(s, ",", fixed = TRUE)[[1]])
      if (length(p) != 2) abort_config("filter '", nm, "' range must be 'min,max'")
      lo <- parse1(p[1]); hi <- parse1(p[2])
    } else {
      return(parse1(s))
    }
  }
  if (kind %in% c("int", "num") && as.numeric(lo) > as.numeric(hi)) {
    abort_config("filter '", nm, "': min (", lo, ") is greater than max (", hi, ")")
  }
  if (kind == "date" && nchar(lo) == nchar(hi) && lo > hi) {
    abort_config("filter '", nm, "': min (", lo, ") is after max (", hi, ")")
  }
  if (nm == "month" && (as.numeric(lo) < 1 || as.numeric(hi) > 12)) abort_config("filter 'month' must be within 1-12")
  if (nm == "year" && as.numeric(lo) < 1) abort_config("filter 'year' must be positive")
  paste0(lo, ",", hi)
}

.normalize_filter_value <- function(nm, val, spec) {
  switch(spec$type,
    enum = {
      v <- .as_chr(nm, val)
      bad <- setdiff(v, spec$values)
      if (length(bad)) abort_config("filter '", nm, "' has invalid value(s): ", paste(bad, collapse = ", "),
                                    ". Allowed: ", paste(spec$values, collapse = ", "))
      unique(v)
    },
    character = unique(.as_chr(nm, val)),
    country = {
      v <- toupper(.as_chr(nm, val))
      if (!all(grepl("^[A-Z]{2}$", v))) abort_config("filter '", nm, "' must be 2-letter ISO country codes")
      unique(v)
    },
    integer = {
      v <- suppressWarnings(as.numeric(unlist(val, use.names = FALSE)))
      if (length(v) == 0 || anyNA(v) || any(v != round(v))) abort_config("filter '", nm, "' must be integer key(s)")
      unique(v)
    },
    logical = {
      if (!is.logical(val) || length(val) != 1 || is.na(val)) abort_config("filter '", nm, "' must be true or false")
      val
    },
    range = .normalize_range(nm, val, spec$kind),
    generic = {
      if (is.list(val) || length(val) == 0) abort_config("filter '", nm, "' must be a scalar or a list of scalars")
      v <- unlist(val, use.names = FALSE)
      if (anyNA(v)) abort_config("filter '", nm, "' has NA values")
      unique(v)
    },
    abort_config("internal: unknown filter type for '", nm, "'")
  )
}

#' Validate and normalise GBIF filters
#'
#' Checks filter names (against the registry and the arguments of
#' [rgbif::occ_data()]), value types, allowed values, ranges and
#' incompatibilities. Filters set to `null` are ignored.
#'
#' @param filters Named list from the YAML `gbif.filters` section.
#' @return A named list of normalised filter values (character/numeric
#'   vectors, logicals, or `"min,max"` strings for ranges).
#' @export
normalize_gbif_filters <- function(filters) {
  if (is.null(filters) || length(filters) == 0) return(list())
  if (!is.list(filters) || is.null(names(filters)) || any(!nzchar(names(filters)))) {
    abort_config("gbif.filters must be a mapping of filter names to values")
  }
  reg <- gbif_filter_registry()
  valid_args <- setdiff(names(formals(rgbif::occ_data)), .gbif_reserved_args())
  out <- list()
  for (nm in names(filters)) {
    val <- filters[[nm]]
    if (is.null(val)) { lg_debug("Filter '", nm, "' is null and was ignored"); next }
    if (nm %in% .gbif_reserved_args()) {
      abort_config("'", nm, "' is controlled by the tool and cannot be set as a filter")
    }
    spec <- reg[[nm]]
    if (is.null(spec)) {
      if (!nm %in% valid_args) {
        hint <- agrep(nm, c(names(reg), valid_args), value = TRUE, max.distance = 0.2)
        abort_config("unknown GBIF filter '", nm, "'",
                     if (length(hint)) paste0(". Did you mean: ", paste(unique(hint), collapse = ", "), "?") else "")
      }
      spec <- list(type = "generic")
    }
    out[[nm]] <- .normalize_filter_value(nm, val, spec)
  }
  if (identical(out$hasCoordinate, FALSE)) {
    abort_config("hasCoordinate = false is incompatible with the spatial (geometry) query, which only returns georeferenced records")
  }
  out
}

#' Expand multi-valued filters into single-valued query sets
#'
#' Multi-valued filters (e.g. several `basisOfRecord` values) are executed as
#' one request per combination (OR semantics within a filter) and merged later,
#' which does not depend on how a given rgbif version encodes vectors.
#'
#' @param filters Normalised filters from [normalize_gbif_filters()].
#' @param max_combinations Maximum number of requests allowed.
#' @return A list of argument lists, one per request.
#' @keywords internal
expand_filter_sets <- function(filters, max_combinations = 50L) {
  if (length(filters) == 0) return(list(list()))
  grid <- expand.grid(lapply(filters, function(v) seq_along(v)), KEEP.OUT.ATTRS = FALSE)
  if (nrow(grid) > max_combinations) {
    abort_config("filters expand to ", nrow(grid), " requests (limit ", max_combinations,
                 "; see gbif.query.max_filter_combinations)")
  }
  lapply(seq_len(nrow(grid)), function(i) {
    set <- lapply(names(filters), function(nm) filters[[nm]][grid[i, nm]])
    stats::setNames(set, names(filters))
  })
}

#' Defaults of rgbif that would act as implicit filters
#'
#' Some `rgbif::occ_data()` arguments have non-NULL defaults (notably
#' `occurrenceStatus = "PRESENT"` in recent versions). To avoid silently adding
#' scientific filters, every such argument not configured by the user is
#' explicitly set to `NULL`.
#'
#' @param configured Names of filters set by the user.
#' @return A named list of `NULL`s (arguments to override).
#' @keywords internal
rgbif_default_overrides <- function(configured) {
  fm <- formals(rgbif::occ_data)
  cand <- setdiff(names(fm), c(.gbif_reserved_args(), configured))
  hit <- character()
  for (nm in cand) {
    if (identical(fm[[nm]], quote(expr = ))) next
    if (is.null(fm[[nm]])) next
    hit <- c(hit, nm)
  }
  if (length(hit)) lg_debug("rgbif default arguments overridden with NULL: ", paste(hit, collapse = ", "))
  stats::setNames(vector("list", length(hit)), hit)
}
