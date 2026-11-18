# One ENE history per upstream series_key. The catalog carries the dimensional inventory.
ene_regions <- c(
  nacional = "Nacional", arica_parinacota = "Arica y Parinacota", tarapaca = "Tarapacá",
  antofagasta = "Antofagasta", atacama = "Atacama", coquimbo = "Coquimbo",
  valparaiso = "Valparaíso", metropolitana = "Metropolitana", ohiggins = "O’Higgins",
  maule = "Maule", nuble = "Ñuble", biobio = "Biobío", araucania = "La Araucanía",
  los_rios = "Los Ríos", los_lagos = "Los Lagos", aysen = "Aysén", magallanes = "Magallanes"
)
ene_sexes <- c(total = "", mujer = "Mujeres", hombre = "Hombres")

ene_name <- function(spec, indicator, branches) {
  age <- spec$age_group
  if (!is.null(age)) {
    age <- if (endsWith(age, "+")) paste(sub("[+]$", "", age), "años o más") else
      paste(sub("-", " a ", age, fixed = TRUE), "años")
  }
  branch <- if (!is.null(spec$branch)) branches[[spec$branch]]$label
  parts <- c(indicator$label, ene_regions[[spec$region]], ene_sexes[[spec$sex]], age, branch)
  parts <- trimws(gsub("[[:space:]]+", " ", sub(" *\\[[0-9]+\\]$", "", parts)))
  paste(parts[nzchar(parts)], collapse = " · ")
}

ene_observations <- function(dates, values, quality) {
  warnings <- c("poco_fiable", "no_fiable")
  stopifnot(all(quality %in% c("sin_advertencia", "sin_dato", warnings)),
            all(is.na(values) == (quality == "sin_dato")),
            all(is.finite(values[!is.na(values)])))
  lapply(seq_along(dates), function(i) {
    point <- list(date = dates[[i]], value = values[[i]])
    if (quality[[i]] %in% warnings) point$quality <- quality[[i]]
    point
  })
}

read_laboral <- function(previous, old_records, series_dir, fetched_at) {
  root <- Sys.getenv("LABORAL_DATA_API", "https://miparrar.github.io/laboral-data/api/v1")
  read_source <- function(path, simplify = FALSE) {
    jsonlite::fromJSON(paste0(sub("/$", "", root), "/", path), simplifyVector = simplify)
  }
  catalog <- read_source("catalog.json")
  stopifnot(catalog$schema_version == 2L, length(catalog$datasets) > 0L)
  index_by <- function(items, field) {
    if (is.null(items)) return(list())
    keys <- vapply(items, function(x) x[[field]], character(1))
    stopifnot(!anyDuplicated(keys))
    setNames(items, keys)
  }
  datasets <- index_by(catalog$datasets, "id")
  records <- entries <- histories <- versions <- list()
  for (dataset in datasets) {
    id <- dataset$id
    stopifnot(grepl("^[a-z0-9_]+$", id), dataset$path == paste0("series/", id, ".json"),
              dataset$frequency == "rolling_quarter", dataset$status == "ok",
              all(grepl("^[a-f0-9]{64}$", c(dataset$source_sha256, dataset$build_sha256))),
              length(dataset$series) > 0L)
    specs <- index_by(dataset$series, "series_key")
    keys <- names(specs)
    stopifnot(all(startsWith(keys, paste0(id, "/"))),
              all(grepl("^[a-z0-9_+-]+(/[a-z0-9_+-]+)+$", keys)))
    ids <- paste0("INE.ENE.", chartr("/", ".", keys))
    # Include inventory/label changes independently of the source and build hashes.
    signature_file <- tempfile()
    writeLines(as.character(jsonlite::toJSON(dataset, auto_unbox = TRUE, null = "null")),
               signature_file, useBytes = TRUE)
    inventory_md5 <- unname(tools::md5sum(signature_file))
    unlink(signature_file)
    version <- list(source_sha256 = dataset$source_sha256, build_sha256 = dataset$build_sha256,
                    inventory_md5 = inventory_md5, adapter_version = 2L, series_count = length(ids))
    versions[[id]] <- version
    if (identical(version, previous$laboral_data[[id]]) &&
        all(ids %in% names(old_records)) && all(ids %in% names(previous$series)) &&
        all(file.exists(file.path(series_dir, paste0(ids, ".json"))))) {
      records[ids] <- old_records[ids]
      entries[ids] <- previous$series[ids]
      message(id, ": reutilizadas ", length(ids), " historias")
      next
    }

    tab <- read_source(dataset$path, simplify = TRUE)
    obs <- tab$observations
    dimensions <- intersect(c("region", "sex", "age_group", "branch"), names(obs))
    stopifnot(tab$schema_version == 1L, identical(tab$id, id),
              identical(tab$frequency, dataset$frequency), identical(tab$source_sha256, dataset$source_sha256),
              nrow(obs) == dataset$observations, all(c("region", "sex") %in% dimensions))
    row_keys <- do.call(paste, c(list(id), as.list(obs[c("indicator", dimensions)]), sep = "/"))
    groups <- split(seq_len(nrow(obs)), row_keys)
    stopifnot(setequal(names(groups), keys))
    indicators <- index_by(dataset$indicators, "id")
    branches <- index_by(dataset$dimension_labels$branch, "id")
    for (i in seq_along(keys)) {
      key <- keys[[i]]
      series_id <- ids[[i]]
      spec <- specs[[key]]
      group <- obs[groups[[key]], , drop = FALSE]
      group <- group[order(group$period), , drop = FALSE]
      stopifnot(nrow(group) == spec$observations, sum(!is.na(group$value)) == spec$valid_observations,
                !anyDuplicated(group$period), group$period[[1L]] == spec$first_period,
                tail(group$period, 1L) == spec$last_period, all(group$unit == spec$unit),
                all(group$source_sheet == spec$source_sheet))
      indicator <- indicators[[spec$indicator]]
      name <- ene_name(spec, indicator, branches)
      provenance <- list(provider = "laboral-data", source_series_key = key)
      common <- c(list(frequency = dataset$frequency, kind = "official", official = TRUE), provenance)
      dates <- paste0(group$period, "-01")
      series_fields <- c(list(name = name), common,
                         list(last_observation = tail(dates, 1L), fetched_at = fetched_at))
      entries[[series_id]] <- c(list(path = paste0("series/", series_id, ".json")), series_fields,
                                 list(observation_count = nrow(group), status = "ok"))
      histories[[series_id]] <- list(
        series_id = series_id, name = name, frequency = dataset$frequency,
        kind = "official", official = TRUE, source = tab$source, fetched_at = fetched_at,
        last_observation = tail(dates, 1L),
        observations = ene_observations(dates, group$value, group$quality)
      )
      records[[series_id]] <- c(list(series_id = series_id, spanish_title = name, english_title = NULL,
        first_observation = dates[[1L]], last_observation = tail(dates, 1L),
        updated_at = substr(catalog$updated_at, 1L, 10L), created_at = NULL,
        display_name = name, measure = indicator$analysis$measurement_type, unit = spec$unit,
        dimensions = spec[dimensions], adjustment = NULL, source = tab$source, enrichment_version = enrichment_version), common)
    }
    message(id, ": generadas ", length(ids), " historias")
  }
  stopifnot(!anyDuplicated(vapply(records, function(x) x$display_name, character(1))))
  list(records = records, entries = entries, histories = histories, datasets = versions)
}
