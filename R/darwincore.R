# Darwin Core Archive (DwC-A) output --------------------------------------------
#
# One archive per area: occurrence.txt (tab-delimited core), meta.xml, eml.xml and
# provenance.yaml, zipped. Columns are mapped to term URIs; columns that are not
# Darwin Core / GBIF / Dublin Core terms are kept in the record-level term
# dynamicProperties (JSON) instead of inventing terms.

.DWC_NS <- "http://rs.tdwg.org/dwc/terms/"
.GBIF_NS <- "http://rs.gbif.org/terms/1.0/"
.DC_NS <- "http://purl.org/dc/terms/"

.DC_TERMS <- c("type", "modified", "language", "license", "rightsHolder", "accessRights", "bibliographicCitation", "references")
.DWC_ONLY <- c(
  "institutionID", "collectionID", "datasetID", "institutionCode", "collectionCode", "datasetName", "ownerInstitutionCode",
  "basisOfRecord", "informationWithheld", "dataGeneralizations", "dynamicProperties",
  "occurrenceID", "catalogNumber", "recordNumber", "recordedBy", "recordedByID", "individualCount", "organismQuantity",
  "organismQuantityType", "sex", "lifeStage", "reproductiveCondition", "caste", "behavior", "vitality", "establishmentMeans",
  "degreeOfEstablishment", "pathway", "georeferenceVerificationStatus", "occurrenceStatus", "preparations", "disposition",
  "associatedMedia", "associatedOccurrences", "associatedReferences", "associatedSequences", "associatedTaxa",
  "otherCatalogNumbers", "occurrenceRemarks", "organismID", "organismName", "organismScope",
  "eventID", "parentEventID", "samplingProtocol", "sampleSizeValue", "sampleSizeUnit", "samplingEffort", "eventDate", "eventTime",
  "startDayOfYear", "endDayOfYear", "year", "month", "day", "verbatimEventDate", "habitat", "fieldNumber", "fieldNotes", "eventRemarks",
  "locationID", "higherGeographyID", "higherGeography", "continent", "waterBody", "islandGroup", "island", "country", "countryCode",
  "stateProvince", "county", "municipality", "locality", "verbatimLocality", "verbatimElevation", "verticalDatum", "verbatimDepth",
  "minimumElevationInMeters", "maximumElevationInMeters", "minimumDepthInMeters", "maximumDepthInMeters",
  "minimumDistanceAboveSurfaceInMeters", "maximumDistanceAboveSurfaceInMeters", "locationAccordingTo", "locationRemarks",
  "decimalLatitude", "decimalLongitude", "geodeticDatum", "coordinateUncertaintyInMeters", "coordinatePrecision",
  "pointRadiusSpatialFit", "verbatimCoordinates", "verbatimLatitude", "verbatimLongitude", "verbatimCoordinateSystem", "verbatimSRS",
  "footprintWKT", "footprintSRS", "footprintSpatialFit", "georeferencedBy", "georeferencedDate", "georeferenceProtocol",
  "georeferenceSources", "georeferenceRemarks",
  "identificationID", "verbatimIdentification", "identificationQualifier", "typeStatus", "identifiedBy", "identifiedByID",
  "dateIdentified", "identificationReferences", "identificationVerificationStatus", "identificationRemarks",
  "taxonID", "scientificNameID", "acceptedNameUsageID", "parentNameUsageID", "originalNameUsageID", "nameAccordingToID",
  "namePublishedInID", "taxonConceptID", "scientificName", "acceptedNameUsage", "parentNameUsage", "originalNameUsage",
  "nameAccordingTo", "namePublishedIn", "namePublishedInYear", "higherClassification", "kingdom", "phylum", "class", "order",
  "superfamily", "family", "subfamily", "tribe", "subtribe", "genus", "genericName", "subgenus", "infragenericEpithet",
  "specificEpithet", "infraspecificEpithet", "cultivarEpithet", "taxonRank", "verbatimTaxonRank", "scientificNameAuthorship",
  "vernacularName", "nomenclaturalCode", "taxonomicStatus", "nomenclaturalStatus", "taxonRemarks")
# GBIF-specific interpreted columns found in GBIF downloads (term URIs follow GBIF's namespace)
.GBIF_ONLY <- c(
  "gbifID", "datasetKey", "publishingOrgKey", "publishingCountry", "taxonKey", "acceptedTaxonKey", "kingdomKey", "phylumKey",
  "classKey", "orderKey", "familyKey", "genusKey", "subgenusKey", "speciesKey", "species", "acceptedScientificName",
  "verbatimScientificName", "issue", "mediaType", "lastInterpreted", "lastParsed", "lastCrawled", "protocol", "repatriated",
  "elevation", "elevationAccuracy", "depth", "depthAccuracy", "hasCoordinate", "hasGeospatialIssue", "projectId", "isSequenced",
  "typifiedName")

#' Map column names to term URIs
#'
#' @param cols Character vector of column names.
#' @return A named character vector of URIs (`NA` for columns without a known term).
#' @keywords internal
dwc_term_uris <- function(cols) {
  uri <- rep(NA_character_, length(cols))
  uri[cols %in% .DWC_ONLY] <- paste0(.DWC_NS, cols[cols %in% .DWC_ONLY])
  uri[cols %in% .GBIF_ONLY] <- paste0(.GBIF_NS, cols[cols %in% .GBIF_ONLY])
  uri[cols %in% .DC_TERMS] <- paste0(.DC_NS, cols[cols %in% .DC_TERMS])
  stats::setNames(uri, cols)
}

.xml_escape <- function(x) {
  x <- gsub("&", "&amp;", x, fixed = TRUE)
  x <- gsub("<", "&lt;", x, fixed = TRUE)
  x <- gsub(">", "&gt;", x, fixed = TRUE)
  x <- gsub("\"", "&quot;", x, fixed = TRUE)
  x
}

.json_string <- function(x) {
  x <- gsub("\\", "\\\\", x, fixed = TRUE)
  x <- gsub("\"", "\\\"", x, fixed = TRUE)
  x <- gsub("\n", "\\n", x, fixed = TRUE)
  x <- gsub("\r", "\\r", x, fixed = TRUE)
  gsub("\t", "\\t", x, fixed = TRUE)
}

# Vectorised per-row JSON object for a data frame of extra columns
.json_rows <- function(df) {
  pieces <- lapply(names(df), function(nm) {
    v <- df[[nm]]
    val <- if (is.numeric(v)) ifelse(is.na(v), "null", format(v, digits = 15, trim = TRUE, scientific = FALSE))
           else if (is.logical(v)) ifelse(is.na(v), "null", ifelse(v, "true", "false"))
           else ifelse(is.na(v), "null", paste0("\"", .json_string(as.character(v)), "\""))
    paste0("\"", .json_string(nm), "\":", val)
  })
  paste0("{", do.call(paste, c(pieces, sep = ",")), "}")
}

.to_chr <- function(v) {
  out <- if (is.logical(v)) ifelse(is.na(v), NA_character_, ifelse(v, "true", "false")) else as.character(v)
  out <- gsub("[\t\r\n]+", " ", out)
  out[is.na(out)] <- ""
  out
}

.dwc_meta_xml <- function(cols, uris) {
  f <- vapply(seq_along(cols), function(i) sprintf('    <field index="%d" term="%s"/>', i - 1L, .xml_escape(uris[i])), "")
  paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
         '<archive xmlns="http://rs.tdwg.org/dwc/text/" metadata="eml.xml">\n',
         '  <core encoding="UTF-8" fieldsTerminatedBy="\\t" linesTerminatedBy="\\n" fieldsEnclosedBy="" ignoreHeaderLines="1" rowType="',
         .DWC_NS, 'Occurrence">\n    <files><location>occurrence.txt</location></files>\n    <id index="0"/>\n',
         paste(f, collapse = "\n"), '\n  </core>\n</archive>\n')
}

.dwc_eml <- function(area_id, cfg, prov, df) {
  para <- function(x) paste0("<para>", .xml_escape(x), "</para>")
  yr <- suppressWarnings(as.numeric(df$year)); yr <- yr[is.finite(yr)]
  lat <- suppressWarnings(as.numeric(df$decimalLatitude)); lon <- suppressWarnings(as.numeric(df$decimalLongitude))
  bb <- prov$bbox
  if (is.null(bb) || length(bb) != 4 || anyNA(bb)) {
    bb <- if (sum(is.finite(lat) & is.finite(lon)) > 0) c(min(lon, na.rm = TRUE), max(lon, na.rm = TRUE), min(lat, na.rm = TRUE), max(lat, na.rm = TRUE)) else NULL
  }
  title <- cfg$title %||% paste0(prov$project, " - GBIF occurrences - ", area_id)
  abstract <- cfg$abstract %||% prov$summary
  org <- if (!is.null(cfg$institution)) paste0("<organizationName>", .xml_escape(cfg$institution), "</organizationName>") else ""
  mail <- if (!is.null(cfg$email)) paste0("<electronicMailAddress>", .xml_escape(cfg$email), "</electronicMailAddress>") else ""
  party <- paste0("<individualName><surName>", .xml_escape(cfg$creator), "</surName></individualName>", org, mail)
  rights <- cfg$license_text %||% paste("Records keep the license stated in their `license` field (GBIF-mediated data are published under CC0, CC BY or CC BY-NC).",
                                      if (!is.null(prov$doi)) paste0("Cite the GBIF occurrence download (DOI ", prov$doi, ") when using this dataset.") else "")
  coverage <- ""
  if (!is.null(bb)) {
    coverage <- paste0("<geographicCoverage><geographicDescription>", .xml_escape(paste0("Study area ", area_id)), "</geographicDescription>",
      "<boundingCoordinates><westBoundingCoordinate>", bb[1], "</westBoundingCoordinate><eastBoundingCoordinate>", bb[2],
      "</eastBoundingCoordinate><northBoundingCoordinate>", bb[4], "</northBoundingCoordinate><southBoundingCoordinate>", bb[3],
      "</southBoundingCoordinate></boundingCoordinates></geographicCoverage>")
  }
  if (length(yr)) {
    coverage <- paste0(coverage, "<temporalCoverage><rangeOfDates><beginDate><calendarDate>", min(yr),
                       "</calendarDate></beginDate><endDate><calendarDate>", max(yr), "</calendarDate></endDate></rangeOfDates></temporalCoverage>")
  }
  methods <- paste0("<methodStep><description>", vapply(prov$methods, para, ""), "</description></methodStep>", collapse = "")
  alt <- if (!is.null(prov$doi)) paste0("<alternateIdentifier>", .xml_escape(paste0("https://doi.org/", prov$doi)), "</alternateIdentifier>") else ""
  cite <- if (!is.null(prov$citation)) paste0("<citation>", .xml_escape(prov$citation), "</citation>") else ""
  paste0('<?xml version="1.0" encoding="UTF-8"?>\n',
    '<eml:eml xmlns:eml="eml://ecoinformatics.org/eml-2.1.1" xmlns:dc="http://purl.org/dc/terms/" ',
    'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ',
    'xsi:schemaLocation="eml://ecoinformatics.org/eml-2.1.1 http://rs.gbif.org/schema/eml-gbif-profile/1.1/eml.xsd" ',
    'packageId="', .xml_escape(paste0(prov$run_id, ":", area_id)), '" system="gbif-area-assessment" scope="system" xml:lang="', cfg$language %||% "eng", '">\n',
    '<dataset>', alt, '<title>', .xml_escape(title), '</title>',
    '<creator>', party, '</creator><pubDate>', format(Sys.Date()), '</pubDate><language>', cfg$language %||% "eng", '</language>',
    '<abstract>', para(abstract), '</abstract>',
    '<intellectualRights>', para(rights), '</intellectualRights>',
    if (nzchar(coverage)) paste0('<coverage>', coverage, '</coverage>') else '',
    '<contact>', party, '</contact>',
    '<methods>', methods, '</methods>',
    '</dataset>\n',
    '<additionalMetadata><metadata><gbif><dateStamp>', format(Sys.time(), "%Y-%m-%dT%H:%M:%S"), '</dateStamp>', cite,
    '</gbif></metadata></additionalMetadata>\n</eml:eml>\n')
}

#' Write one Darwin Core Archive (zip) for an area
#'
#' The core is `occurrence.txt` (tab-delimited, header row); `gbifID` is the core
#' id (it must be unique and present). Columns without a known term are stored as
#' JSON in `dynamicProperties`, except the constant `area_id`. `eml.xml` carries
#' the dataset metadata and the processing provenance; `provenance.yaml` holds the
#' same provenance in machine-readable form. Refuses to overwrite an existing zip.
#' Term URIs of GBIF-specific columns use GBIF's namespace; validate the archive
#' (e.g. with the GBIF Data Validator) before publishing it.
#'
#' @param records Data frame or `sf` object with the occurrence records of ONE area.
#' @param dir Output directory.
#' @param area_id Area identifier.
#' @param cfg The `output.darwin_core` configuration block.
#' @param prov Provenance list: `project`, `run_id`, `summary`, `methods` (character
#'   vector of paragraphs), optional `doi`, `citation`, `bbox` (west, east, south, north)
#'   and `details` (list written to `provenance.yaml`).
#' @param prefix File name prefix (e.g. the run label).
#' @return A list with `zip`, `n_records`, `mapped_columns`, `dynamic_columns`.
#' @export
write_dwca <- function(records, dir, area_id, cfg, prov, prefix = "") {
  df <- if (inherits(records, "sf")) sf::st_drop_geometry(records) else as.data.frame(records)
  df$area_id <- NULL
  if (!"gbifID" %in% names(df)) stop("Darwin Core output needs a gbifID column to use as the core id.", call. = FALSE)
  if (anyDuplicated(df$gbifID)) stop("Duplicated gbifID in area '", area_id, "'; cannot build a Darwin Core core id.", call. = FALSE)
  uris <- dwc_term_uris(names(df))
  known <- names(df)[!is.na(uris)]
  extra <- setdiff(names(df), known)
  if (length(extra) && "dynamicProperties" %in% known) {
    lg_warn("Columns without a Darwin Core term were dropped (dynamicProperties already in use): ", paste(extra, collapse = ", "))
    extra <- character()
  }
  cols <- c("gbifID", setdiff(known, "gbifID"))
  out <- lapply(df[cols], .to_chr)
  if (length(extra)) {
    out$dynamicProperties <- .json_rows(df[extra])
    cols <- c(cols, "dynamicProperties")
    lg_info("Darwin Core: ", length(extra), " column(s) without a term stored in dynamicProperties: ", paste(extra, collapse = ", "))
  }
  out <- as.data.frame(out, stringsAsFactors = FALSE, check.names = FALSE)[cols]

  safe <- gsub("[^A-Za-z0-9_-]+", "_", area_id)
  zipfile <- file.path(dir, paste0(prefix, safe, "_dwca.zip"))
  if (file.exists(zipfile)) stop("Refusing to overwrite existing file: ", zipfile, call. = FALSE)
  ensure_dir(dir)
  stage <- tempfile("dwca_"); ensure_dir(stage)
  on.exit(unlink(stage, recursive = TRUE), add = TRUE)
  utils::write.table(out, file.path(stage, "occurrence.txt"), sep = "\t", quote = FALSE, row.names = FALSE,
                     na = "", eol = "\n", fileEncoding = "UTF-8")
  writeLines(.dwc_meta_xml(cols, c(uris[setdiff(cols, "dynamicProperties")], if ("dynamicProperties" %in% cols) paste0(.DWC_NS, "dynamicProperties"))),
             file.path(stage, "meta.xml"), useBytes = TRUE)
  writeLines(.dwc_eml(area_id, cfg, prov, df), file.path(stage, "eml.xml"), useBytes = TRUE)
  yaml::write_yaml(c(list(area_id = area_id, n_records = nrow(out), columns_mapped = setdiff(cols, "dynamicProperties"),
                          columns_in_dynamicProperties = extra), prov$details), file.path(stage, "provenance.yaml"))
  zip::zip(zipfile, c("occurrence.txt", "meta.xml", "eml.xml", "provenance.yaml"), root = stage, mode = "cherry-pick")
  lg_info("Darwin Core archive written: ", zipfile, " (", nrow(out), " records)")
  list(zip = zipfile, n_records = nrow(out), mapped_columns = setdiff(cols, "dynamicProperties"), dynamic_columns = extra)
}
