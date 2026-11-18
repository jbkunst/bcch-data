#!/usr/bin/env Rscript
source("scripts/bcch_data.R")
source("scripts/laboral_data.R")

args <- commandArgs(trailingOnly = TRUE)
stopifnot(all(args %in% "--laboral-only"))
laboral_only <- "--laboral-only" %in% args
api <- file.path("api", "v1")
series_dir <- file.path(api, "series")
dir.create(series_dir, recursive = TRUE, showWarnings = FALSE)
fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
read_existing <- function(file) {
  path <- file.path(api, file)
  if (file.exists(path)) jsonlite::read_json(path) else NULL
}
write_api <- function(x, path, pretty = FALSE) {
  jsonlite::write_json(x, path, auto_unbox = TRUE, digits = NA,
                       na = "null", null = "null", pretty = pretty)
}

previous <- read_existing("manifest.json")
old_catalog <- read_existing("catalog.json")
old_records <- if (is.null(old_catalog)) list() else old_catalog$series
names(old_records) <- vapply(old_records, function(x) x$series_id, character(1))

if (laboral_only) {
  stopifnot(!is.null(previous), !is.null(old_catalog))
  # Keep the existing BCCh snapshot, including its indicators and freshness.
  entries <- previous$series[!startsWith(names(previous$series), "INE.ENE.")]
  records <- old_records[!startsWith(names(old_records), "INE.ENE.")]
  histories <- list()
  indicator_count <- previous$indicator_count
  bcch_updated_at <- if (is.null(previous$bcch_updated_at)) previous$updated_at else previous$bcch_updated_at
} else {
  bcch <- refresh_bcch(fetched_at)
  entries <- bcch$entries
  records <- jsonlite::fromJSON(jsonlite::toJSON(bcch$records, na = "null"),
                                simplifyVector = FALSE)
  names(records) <- bcch$records$series_id
  histories <- bcch$histories
  indicator_count <- length(bcch$indicators)
  bcch_updated_at <- fetched_at
}

laboral <- read_laboral(previous, old_records, series_dir, fetched_at)
if (length(intersect(names(records), names(laboral$records)))) {
  stop("ENE ID collision with an existing series")
}
records <- c(records, laboral$records)
entries <- c(entries, laboral$entries)
histories <- c(histories, laboral$histories)
records <- records[order(names(records), method = "radix")]
stopifnot(!anyDuplicated(names(records)), !anyDuplicated(names(entries)))

if (laboral_only && identical(previous$laboral_data, laboral$datasets) &&
    identical(entries, previous$series) && !length(histories) &&
    identical(records, old_records)) {
  message("La caché ENE ya está actualizada.")
  quit(status = 0L)
}

for (id in names(histories)) {
  write_api(histories[[id]], file.path(series_dir, paste0(id, ".json")),
            pretty = !startsWith(id, "INE.ENE."))
}
catalog_updated_at <- old_catalog$updated_at
if (!identical(records, old_records)) {
  catalog_updated_at <- fetched_at
  write_api(list(schema_version = 1L, updated_at = catalog_updated_at,
                 series_count = length(records), series = unname(records)),
            file.path(api, "catalog.json"))
}
if (!laboral_only) {
  write_api(list(updated_at = fetched_at, indicator_count = indicator_count,
                 indicators = bcch$indicators), file.path(api, "indicators.json"), pretty = TRUE)
}
orphan_files <- setdiff(list.files(series_dir, pattern = "[.]json$"), paste0(names(entries), ".json"))
if (length(orphan_files)) stopifnot(all(file.remove(file.path(series_dir, orphan_files))))
manifest <- list(schema_version = 1L, updated_at = fetched_at, bcch_updated_at = bcch_updated_at,
                 catalog_path = "catalog.json", catalog_series_count = length(records),
                 catalog_updated_at = catalog_updated_at, series_count = length(entries),
                 indicators_path = "indicators.json", indicator_count = indicator_count,
                 laboral_data = laboral$datasets, series = entries)
write_api(manifest, file.path(api, "manifest.json"), pretty = TRUE)
message(length(laboral$records), " series ENE en ", length(entries), " historias publicadas.")
