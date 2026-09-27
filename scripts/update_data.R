#!/usr/bin/env Rscript

log_inform <- function(message, .envir = parent.frame()) {
  message <- cli::format_inline(message, .envir = .envir)
  cli::cli_inform(paste0("[", format(Sys.time(), "%H:%M:%S"), "] ", message))
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

token <- Sys.getenv("BCCH_TOKEN")
if (!nzchar(token)) {
  cli::cli_abort("BCCH_TOKEN is not configured.")
}

catalog <- yaml::read_yaml(file.path("config", "series.yml"))$series
series_ids <- vapply(catalog, function(x) x$id, character(1))
series_names <- setNames(
  vapply(catalog, function(x) x$name, character(1)),
  series_ids
)

if (anyDuplicated(series_ids) || any(!nzchar(series_ids)) || any(!nzchar(series_names))) {
  cli::cli_abort("Every catalog entry needs a unique id and a non-empty name.")
}

indicators <- yaml::read_yaml(file.path("config", "indicators.yml"))$indicators
indicator_ids <- vapply(indicators, function(x) x$id, character(1))
indicator_series_ids <- vapply(indicators, function(x) x$series_id, character(1))
period_types <- vapply(indicators, function(x) x$period_type, character(1))

if (anyDuplicated(indicator_ids) || any(!indicator_series_ids %in% series_ids)) {
  cli::cli_abort("Indicators need unique IDs and series present in config/series.yml.")
}
if (any(!period_types %in% c("daily", "monthly", "quarterly", "rolling_quarter"))) {
  cli::cli_abort("Every indicator needs a supported period_type.")
}

cli::cli_h1("Updating bcch-data")
cli::cli_alert_success("Loaded {length(series_ids)} unique series from {.path config/series.yml}.")

cli::cli_h2("Reading BCCh metadata")
cli::cli_alert_info("Checking that every configured ID exists in the BCCh catalog.")
metadata <- bcchr::metadata(token = token, verbose = FALSE)
unknown_ids <- setdiff(series_ids, metadata$series_id)
if (length(unknown_ids) > 0L) {
  cli::cli_abort(c(
    "Series not found in BCCh metadata:",
    "*" = paste(unknown_ids, collapse = ", ")
  ))
}
cli::cli_alert_success("All {length(series_ids)} IDs were found in BCCh metadata.")

cli::cli_h2("Downloading observations")
cli::cli_alert_info("Downloading the complete history of {length(series_ids)} series.")
fetched_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
payloads <- setNames(vector("list", length(series_ids)), series_ids)
manifest_series <- setNames(vector("list", length(series_ids)), series_ids)
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
    source = "Banco Central de Chile",
    fetched_at = fetched_at,
    last_observation = tail(observations$date, 1L),
    observations = observations
  )
  manifest_series[[id]] <- list(
    path = paste0("series/", id, ".json"),
    name = series_names[[id]],
    frequency = frequency,
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

series_dir <- file.path("api", "v1", "series")
dir.create(series_dir, recursive = TRUE, showWarnings = FALSE)

cli::cli_h2("Writing static API")
cli::cli_progress_bar("Writing JSON files", total = length(series_ids))
for (id in series_ids) {
  jsonlite::write_json(
    payloads[[id]],
    file.path(series_dir, paste0(id, ".json")),
    auto_unbox = TRUE,
    pretty = TRUE,
    digits = NA
  )
  cli::cli_progress_update()
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
  !basename(existing_files) %in% paste0(series_ids, ".json")
]
unlink(orphan_files)
if (length(orphan_files) > 0L) {
  cli::cli_alert_info("Removed {length(orphan_files)} JSON files not present in the catalog.")
}

manifest <- list(
  updated_at = fetched_at,
  series_count = length(series_ids),
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
    "Series" = length(series_ids),
    "Observations" = sum(vapply(manifest_series, function(x) x$observation_count, numeric(1))),
    "Fetched at" = fetched_at,
    "Manifest" = file.path("api", "v1", "manifest.json"),
    "Indicators" = indicators_path,
    "Series directory" = series_dir
  )
)
