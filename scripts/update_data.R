#!/usr/bin/env Rscript

log_inform <- function(message, .envir = parent.frame()) {
  message <- cli::format_inline(message, .envir = .envir)
  cli::cli_inform(paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", message))
}

enrichment_version <- 3L

collapse_parts <- function(parts, matches) {
  values <- parts[matches]
  if (length(values)) paste(values, collapse = " · ") else NA_character_
}

enrich_title <- function(title) {
  parts <- trimws(strsplit(title, "\\s*[|\\\\]\\s*")[[1]])
  parts <- parts[nzchar(parts)]

  if (!length(parts)) {
    return(c(
      display_name = NA_character_,
      measure = NA_character_,
      unit = NA_character_,
      adjustment = NA_character_,
      source = NA_character_
    ))
  }

  details <- parts[-1L]
  normalized <- iconv(tolower(details), to = "ASCII//TRANSLIT")
  frequency_match <- grepl(
    "^(diari[oa]|semanal|mensual|trimestral|semestral|anual)$",
    normalized
  )
  adjustment_match <- grepl(
    "estacional|desestacional|tendencia|ciclo|original|ajustad",
    normalized
  )
  source_match <- grepl(
    "^(bcch|ine|fmi|imf|ocde|oecd|bcentral|banco central|ministerio|superintendencia)",
    normalized
  )
  adjustment_match <- adjustment_match & !source_match
  unit_match <- !source_match & !adjustment_match & grepl(
    paste(
      "porcentaje|indice|pesos?|dolares?|usd|clp|uf|utm|puntos?",
      "millones?|miles?|numero|personas?|toneladas?|kilogramos?|hectareas?|unidad",
      sep = "|"
    ),
    normalized
  )
  measure_match <- !(frequency_match | adjustment_match | source_match | unit_match)

  c(
    display_name = parts[[1]],
    measure = collapse_parts(details, measure_match),
    unit = collapse_parts(details, unit_match),
    adjustment = collapse_parts(details, adjustment_match),
    source = collapse_parts(details, source_match)
  )
}

enrich_catalog <- function(metadata) {
  editorial <- lapply(metadata$spanish_title, enrich_title)
  editorial <- as.data.frame(do.call(rbind, editorial), stringsAsFactors = FALSE)
  metadata[names(editorial)] <- editorial
  metadata$enrichment_version <- enrichment_version
  metadata
}

# Aplica unidades editoriales explícitas sólo a las historias configuradas.
apply_official_units <- function(metadata, specs) {
  for (spec in specs) {
    if (is.null(spec$unit)) next
    index <- match(spec$id, metadata$series_id)
    if (is.na(index)) {
      cli::cli_abort("Configured series {spec$id} is missing from catalog metadata.")
    }
    metadata$unit[[index]] <- spec$unit
  }
  metadata
}

format_catalog_date <- function(value) {
  dates <- suppressWarnings(as.Date(value))
  ifelse(is.na(dates), NA_character_, format(dates, "%Y-%m-%d"))
}

format_indicator_value <- function(value, indicator) {
  number <- formatC(
    value,
    format = "f",
    digits = indicator$digits,
    big.mark = ".",
    decimal.mark = ","
  )
  paste0(indicator$prefix, number, indicator$suffix)
}

format_indicator_period <- function(date, period_type) {
  date <- as.Date(date)
  months <- c("ene", "feb", "mar", "abr", "may", "jun", "jul", "ago", "sep", "oct", "nov", "dic")
  month <- as.integer(format(date, "%m"))
  year <- format(date, "%Y")

  if (period_type == "rolling_quarter") {
    dates <- rev(seq(as.Date(format(date, "%Y-%m-01")), by = "-1 month", length.out = 3L))
    labels <- months[as.integer(format(dates, "%m"))]
    years <- format(dates, "%Y")
    if (length(unique(years)) > 1L) {
      return(paste(paste(labels, years), collapse = "-"))
    }
    return(paste(paste(labels, collapse = "-"), year))
  }

  switch(
    period_type,
    quarterly = paste0((month - 1L) %/% 3L + 1L, ".º trimestre ", year),
    monthly = paste(months[[month]], year),
    daily = paste(as.integer(format(date, "%d")), months[[month]], year)
  )
}

derived_source <- "Cálculo bcch-data a partir de series del Banco Central de Chile"

# Valida IDs, nombres y unidades editoriales antes de consultar la API.
validate_official_series <- function(specs) {
  allowed <- c("id", "name", "unit")
  for (spec in specs) {
    unexpected <- setdiff(names(spec), allowed)
    valid_unit <- is.null(spec$unit) ||
      (is.character(spec$unit) && length(spec$unit) == 1L && nzchar(spec$unit))
    if (!is.character(spec$id) || length(spec$id) != 1L || !nzchar(spec$id) ||
        !is.character(spec$name) || length(spec$name) != 1L || !nzchar(spec$name) ||
        length(unexpected) || !valid_unit) {
      cli::cli_abort(
        "Official series entries need id, name and an optional non-empty unit."
      )
    }
  }
  invisible(specs)
}

validate_derived_series <- function(specs, official_ids) {
  required <- c(
    "id", "name", "english_name", "frequency", "unit", "measure",
    "adjustment", "operation", "source_ids", "formula", "reference_url"
  )

  for (spec in specs) {
    missing <- setdiff(required, names(spec))
    if (length(missing)) {
      label <- if (!is.null(spec$id) && length(spec$id) == 1L && nzchar(spec$id)) {
        spec$id
      } else {
        "<unknown>"
      }
      cli::cli_abort(
        "Derived series {label} is missing: {paste(missing, collapse = ', ')}."
      )
    }
    source_ids <- unname(unlist(spec$source_ids, use.names = FALSE))
    expected_formula <- paste(source_ids, collapse = " - ")
    if (!startsWith(spec$id, "BCCHDATA.") || !nzchar(spec$name) ||
        !nzchar(spec$english_name) || !identical(spec$operation, "subtract") ||
        length(source_ids) != 2L || anyDuplicated(source_ids) ||
        any(!source_ids %in% official_ids) ||
        !identical(spec$formula, expected_formula) ||
        !grepl("^https://", spec$reference_url)) {
      cli::cli_abort(
        paste(
          "Derived series {spec$id} needs a BCCHDATA ID, two distinct configured",
          "sources, their subtract formula and an HTTPS reference URL."
        )
      )
    }
  }

  invisible(specs)
}

derive_series <- function(spec, payloads, fetched_at) {
  source_ids <- unname(unlist(spec$source_ids, use.names = FALSE))
  minuend <- payloads[[source_ids[[1L]]]]
  subtrahend <- payloads[[source_ids[[2L]]]]
  if (!identical(minuend$frequency, spec$frequency) ||
      !identical(subtrahend$frequency, spec$frequency)) {
    cli::cli_abort("Derived series {spec$id} has incompatible source frequencies.")
  }

  minuend_dates <- as.character(minuend$observations$date)
  subtrahend_dates <- as.character(subtrahend$observations$date)
  if (!identical(minuend_dates, subtrahend_dates)) {
    cli::cli_abort("Derived series {spec$id} requires identical source dates.")
  }

  values <- minuend$observations$value - subtrahend$observations$value
  if (any(!is.finite(values))) {
    cli::cli_abort("Derived series {spec$id} produced non-finite values.")
  }
  observations <- data.frame(
    date = minuend_dates,
    value = values,
    stringsAsFactors = FALSE
  )

  list(
    series_id = spec$id,
    name = spec$name,
    frequency = spec$frequency,
    kind = "derived",
    official = FALSE,
    source = derived_source,
    source_series = source_ids,
    operation = spec$operation,
    formula = spec$formula,
    reference_url = spec$reference_url,
    fetched_at = fetched_at,
    last_observation = tail(observations$date, 1L),
    observations = observations
  )
}

derived_catalog_record <- function(spec, payload, catalog_data) {
  source_ids <- unname(unlist(spec$source_ids, use.names = FALSE))
  source_rows <- catalog_data[match(source_ids, catalog_data$series_id), , drop = FALSE]
  if (anyNA(source_rows$series_id)) {
    cli::cli_abort("Derived series {spec$id} has sources missing from catalog metadata.")
  }

  latest_source_date <- function(field) {
    values <- source_rows[[field]]
    values <- values[!is.na(values) & nzchar(values)]
    if (length(values)) max(values) else NA_character_
  }

  data.frame(
    series_id = spec$id,
    frequency = spec$frequency,
    spanish_title = paste0(spec$name, ", ", tolower(spec$measure)),
    english_title = spec$english_name,
    first_observation = payload$observations$date[[1L]],
    last_observation = tail(payload$observations$date, 1L),
    updated_at = latest_source_date("updated_at"),
    created_at = latest_source_date("created_at"),
    display_name = spec$name,
    measure = spec$measure,
    unit = spec$unit,
    adjustment = spec$adjustment,
    source = derived_source,
    kind = "derived",
    official = FALSE,
    enrichment_version = enrichment_version,
    stringsAsFactors = FALSE
  )
}

token <- Sys.getenv("BCCH_TOKEN")
if (!nzchar(token)) {
  cli::cli_abort("BCCH_TOKEN is not configured.")
}

series_config <- yaml::read_yaml(file.path("config", "series.yml"))
catalog <- series_config$series
derived_catalog <- series_config$derived_series
if (is.null(derived_catalog)) derived_catalog <- list()
series_ids <- vapply(catalog, function(x) x$id, character(1))
official_series_names <- setNames(
  vapply(catalog, function(x) x$name, character(1)),
  series_ids
)
derived_series_ids <- vapply(derived_catalog, function(x) x$id, character(1))
derived_series_names <- setNames(
  vapply(derived_catalog, function(x) x$name, character(1)),
  derived_series_ids
)
published_series_ids <- c(series_ids, derived_series_ids)
series_names <- c(official_series_names, derived_series_names)

validate_official_series(catalog)
if (anyDuplicated(published_series_ids) || any(!nzchar(published_series_ids)) ||
    any(!nzchar(series_names))) {
  cli::cli_abort("Every catalog entry needs a unique id and a non-empty name.")
}
validate_derived_series(derived_catalog, series_ids)

indicators <- yaml::read_yaml(file.path("config", "indicators.yml"))$indicators
indicator_ids <- vapply(indicators, function(x) x$id, character(1))
indicator_series_ids <- vapply(indicators, function(x) x$series_id, character(1))
period_types <- vapply(indicators, function(x) x$period_type, character(1))

if (anyDuplicated(indicator_ids) || any(!indicator_series_ids %in% published_series_ids)) {
  cli::cli_abort("Indicators need unique IDs and series present in config/series.yml.")
}
if (any(!period_types %in% c("daily", "monthly", "quarterly", "rolling_quarter"))) {
  cli::cli_abort("Every indicator needs a supported period_type.")
}

cli::cli_h1("Updating bcch-data")
cli::cli_alert_success(
  "Loaded {length(series_ids)} official and {length(derived_series_ids)} derived series from {.path config/series.yml}."
)

cli::cli_h2("Reading BCCh metadata")
cli::cli_alert_info("Checking that every configured ID exists in the BCCh catalog.")
metadata <- bcchr::metadata(token = token, verbose = FALSE)
catalog_fields <- c(
  "series_id", "frequency", "spanish_title", "english_title",
  "first_observation", "last_observation", "updated_at", "created_at"
)
missing_fields <- setdiff(catalog_fields, names(metadata))
if (!is.data.frame(metadata) || nrow(metadata) == 0L || length(missing_fields) > 0L) {
  cli::cli_abort(c(
    "BCCh metadata does not satisfy the catalog contract.",
    "x" = "Missing fields: {paste(missing_fields, collapse = ', ')}"
  ))
}
if (anyDuplicated(metadata$series_id) || any(!nzchar(metadata$series_id))) {
  cli::cli_abort("BCCh metadata contains missing or duplicate series IDs.")
}
unknown_ids <- setdiff(series_ids, metadata$series_id)
if (length(unknown_ids) > 0L) {
  cli::cli_abort(c(
    "Series not found in BCCh metadata:",
    "*" = paste(unknown_ids, collapse = ", ")
  ))
}
cli::cli_alert_success("All {length(series_ids)} IDs were found in BCCh metadata.")

catalog_data <- enrich_catalog(metadata[catalog_fields])
catalog_data <- apply_official_units(catalog_data, catalog)
for (field in c("first_observation", "last_observation", "updated_at", "created_at")) {
  catalog_data[[field]] <- format_catalog_date(catalog_data[[field]])
}
catalog_data <- catalog_data[c(
  "series_id", "frequency", "spanish_title", "english_title",
  "first_observation", "last_observation", "updated_at", "created_at",
  "display_name", "measure", "unit", "adjustment", "source",
  "enrichment_version"
)]
catalog_data$kind <- "official"
catalog_data$official <- TRUE
catalog_data <- catalog_data[c(
  "series_id", "frequency", "spanish_title", "english_title",
  "first_observation", "last_observation", "updated_at", "created_at",
  "display_name", "measure", "unit", "adjustment", "source",
  "kind", "official", "enrichment_version"
)]
catalog_data <- catalog_data[order(catalog_data$series_id), , drop = FALSE]
rownames(catalog_data) <- NULL
cli::cli_alert_success(
  "Prepared metadata for {nrow(catalog_data)} series with enrichment version {enrichment_version}."
)

cli::cli_h2("Downloading observations")
cli::cli_alert_info("Downloading the complete history of {length(series_ids)} series.")
fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
payloads <- setNames(vector("list", length(published_series_ids)), published_series_ids)
manifest_series <- setNames(vector("list", length(published_series_ids)), published_series_ids)
observation_count <- 0L

for (index in seq_along(series_ids)) {
  if (index > 1L && (index - 1L) %% 5L == 0L) {
    Sys.sleep(1)
  }

  id <- series_ids[[index]]
  log_inform("[{index}/{length(series_ids)}] Downloading {.code {id}}...")
  data <- bcchr::get_series(id, token = token)
  dates <- suppressWarnings(as.Date(data$date))
  values <- suppressWarnings(as.numeric(data$value))
  keep <- !is.na(dates) & is.finite(values)

  observations <- data.frame(
    date = format(dates[keep], "%Y-%m-%d"),
    value = values[keep],
    stringsAsFactors = FALSE
  )
  observations <- observations[order(observations$date), , drop = FALSE]

  if (nrow(observations) == 0L) {
    cli::cli_abort("Series {id} has no numeric observations.")
  }
  if (anyDuplicated(observations$date)) {
    cli::cli_abort("Series {id} has duplicate dates.")
  }

  frequency <- metadata$frequency[match(id, metadata$series_id)]
  payloads[[id]] <- list(
    series_id = id,
    name = series_names[[id]],
    frequency = frequency,
    kind = "official",
    official = TRUE,
    source = "Banco Central de Chile",
    fetched_at = fetched_at,
    last_observation = tail(observations$date, 1L),
    observations = observations
  )
  manifest_series[[id]] <- list(
    path = paste0("series/", id, ".json"),
    name = series_names[[id]],
    frequency = frequency,
    kind = "official",
    official = TRUE,
    last_observation = tail(observations$date, 1L),
    observation_count = nrow(observations),
    fetched_at = fetched_at,
    status = "ok"
  )
  observation_count <- observation_count + nrow(observations)

  first_date <- observations$date[[1]]
  last_date <- tail(observations$date, 1L)
  log_inform(
    paste0(
      "[{index}/{length(series_ids)}] OK: {nrow(observations)} observations ",
      "({first_date} to {last_date})."
    )
  )
}
cli::cli_alert_success("Downloaded {observation_count} observations.")

if (length(derived_catalog)) {
  cli::cli_h2("Deriving configured series")
  for (spec in derived_catalog) {
    id <- spec$id
    payload <- derive_series(spec, payloads, fetched_at)
    payloads[[id]] <- payload
    manifest_series[[id]] <- list(
      path = paste0("series/", id, ".json"),
      name = spec$name,
      frequency = spec$frequency,
      kind = "derived",
      official = FALSE,
      source_series = unname(unlist(spec$source_ids, use.names = FALSE)),
      operation = spec$operation,
      formula = spec$formula,
      reference_url = spec$reference_url,
      last_observation = payload$last_observation,
      observation_count = nrow(payload$observations),
      fetched_at = fetched_at,
      status = "ok"
    )
    observation_count <- observation_count + nrow(payload$observations)
    log_inform(
      "Derived {.code {id}} with {nrow(payload$observations)} observations."
    )
  }

  derived_catalog_data <- do.call(
    rbind,
    lapply(derived_catalog, function(spec) {
      derived_catalog_record(spec, payloads[[spec$id]], catalog_data)
    })
  )
  catalog_data <- rbind(catalog_data, derived_catalog_data)
  catalog_data <- catalog_data[order(catalog_data$series_id), , drop = FALSE]
  rownames(catalog_data) <- NULL
}

series_dir <- file.path("api", "v1", "series")
dir.create(series_dir, recursive = TRUE, showWarnings = FALSE)

cli::cli_h2("Writing static API")
cli::cli_progress_bar("Writing JSON files", total = length(published_series_ids))
for (id in published_series_ids) {
  jsonlite::write_json(
    payloads[[id]],
    file.path(series_dir, paste0(id, ".json")),
    auto_unbox = TRUE,
    pretty = TRUE,
    digits = NA
  )
  cli::cli_progress_update()
}

cli::cli_h2("Writing metadata catalog")
catalog_path <- file.path("api", "v1", "catalog.json")
canonical_json <- function(value) {
  as.character(jsonlite::toJSON(
    value,
    auto_unbox = TRUE,
    dataframe = "rows",
    pretty = FALSE,
    digits = NA,
    na = "null"
  ))
}

existing_catalog <- if (file.exists(catalog_path)) {
  tryCatch(
    jsonlite::read_json(catalog_path, simplifyVector = TRUE),
    error = function(error) NULL
  )
} else {
  NULL
}
existing_catalog_valid <-
  is.list(existing_catalog) &&
  isTRUE(existing_catalog$schema_version == 1L) &&
  is.character(existing_catalog$updated_at) &&
  length(existing_catalog$updated_at) == 1L &&
  nzchar(existing_catalog$updated_at) &&
  isTRUE(existing_catalog$series_count == nrow(catalog_data)) &&
  is.data.frame(existing_catalog$series)

candidate_records <- canonical_json(catalog_data)
existing_records <- if (existing_catalog_valid) {
  canonical_json(existing_catalog$series)
} else {
  NULL
}
catalog_changed <- !existing_catalog_valid || !identical(candidate_records, existing_records)
catalog_updated_at <- if (catalog_changed) fetched_at else existing_catalog$updated_at
catalog_payload <- list(
  schema_version = 1L,
  updated_at = catalog_updated_at,
  series_count = nrow(catalog_data),
  series = catalog_data
)

# Compact a legacy pretty-printed file once without changing its metadata version.
catalog_needs_compaction <- file.exists(catalog_path) &&
  length(readLines(catalog_path, n = 2L, warn = FALSE, encoding = "UTF-8")) > 1L

if (catalog_changed || catalog_needs_compaction) {
  jsonlite::write_json(
    catalog_payload,
    catalog_path,
    auto_unbox = TRUE,
    dataframe = "rows",
    pretty = FALSE,
    digits = NA,
    na = "null"
  )
  if (catalog_changed) {
    cli::cli_alert_success(
      "Updated {nrow(catalog_data)} metadata records in {.path {catalog_path}}."
    )
  } else {
    cli::cli_alert_success(
      "Compacted {.path {catalog_path}} without changing its updated_at."
    )
  }
} else {
  cli::cli_alert_success(
    "Catalog metadata is unchanged; preserved {.path {catalog_path}}."
  )
}

cli::cli_h2("Writing indicators")
indicator_payloads <- unname(lapply(indicators, function(indicator) {
  series <- payloads[[indicator$series_id]]
  position <- nrow(series$observations)
  value <- series$observations$value[[position]]
  reference_date <- series$observations$date[[position]]

  list(
    id = indicator$id,
    name = indicator$name,
    series_id = indicator$series_id,
    frequency = series$frequency,
    value = value,
    unit = indicator$unit,
    display_value = format_indicator_value(value, indicator),
    reference_date = reference_date,
    period = format_indicator_period(reference_date, indicator$period_type)
  )
}))

indicators_path <- file.path("api", "v1", "indicators.json")
jsonlite::write_json(
  list(
    updated_at = fetched_at,
    indicator_count = length(indicator_payloads),
    indicators = indicator_payloads
  ),
  indicators_path,
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = NA
)
cli::cli_alert_success("Wrote {length(indicator_payloads)} indicators to {.path {indicators_path}}.")

existing_files <- list.files(series_dir, pattern = "[.]json$", full.names = TRUE)
orphan_files <- existing_files[
  !basename(existing_files) %in% paste0(published_series_ids, ".json")
]
unlink(orphan_files)
if (length(orphan_files) > 0L) {
  cli::cli_alert_info("Removed {length(orphan_files)} JSON files not present in the catalog.")
}

manifest <- list(
  schema_version = 1L,
  updated_at = fetched_at,
  catalog_path = "catalog.json",
  catalog_series_count = nrow(catalog_data),
  catalog_updated_at = catalog_updated_at,
  series_count = length(published_series_ids),
  indicators_path = "indicators.json",
  indicator_count = length(indicator_payloads),
  series = manifest_series
)
jsonlite::write_json(
  manifest,
  file.path("api", "v1", "manifest.json"),
  auto_unbox = TRUE,
  pretty = TRUE,
  digits = NA
)

cli::cli_h1("Update complete")
cli::cli_dl(
  list(
    "Series" = length(published_series_ids),
    "Observations" = sum(vapply(manifest_series, function(x) x$observation_count, numeric(1))),
    "Fetched at" = fetched_at,
    "Catalog" = catalog_path,
    "Catalog series" = nrow(catalog_data),
    "Manifest" = file.path("api", "v1", "manifest.json"),
    "Indicators" = indicators_path,
    "Series directory" = series_dir
  )
)
