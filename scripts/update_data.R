#!/usr/bin/env Rscript

required_packages <- c("bcchr", "jsonlite", "yaml")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]
if (length(missing_packages) > 0L) {
  stop("Missing R packages: ", paste(missing_packages, collapse = ", "), call. = FALSE)
}

script_arg <- grep("^--file=", commandArgs(FALSE), value = TRUE)
if (length(script_arg) != 1L) {
  stop("Run this file with Rscript.", call. = FALSE)
}
project_root <- normalizePath(
  file.path(dirname(sub("^--file=", "", script_arg)), ".."),
  mustWork = TRUE
)
setwd(project_root)

args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 1L || (length(args) == 1L && args != "--validate-only")) {
  stop("Usage: Rscript scripts/update_data.R [--validate-only]", call. = FALSE)
}
validate_only <- identical(args, "--validate-only")

`%||%` <- function(x, y) if (is.null(x)) y else x

config_path <- file.path("config", "series.yml")
manifest_path <- file.path("api", "v1", "manifest.json")
series_dir <- file.path("api", "v1", "series")

catalog <- yaml::read_yaml(config_path)
if (!is.list(catalog$series) || length(catalog$series) == 0L) {
  stop("config/series.yml must declare a non-empty `series` list.", call. = FALSE)
}

series_ids <- vapply(catalog$series, function(x) x$id %||% "", character(1))
groups <- vapply(catalog$series, function(x) x$group %||% "", character(1))
if (any(!nzchar(series_ids)) || any(!nzchar(groups)) || anyDuplicated(series_ids)) {
  stop("Every configured series needs a unique `id` and a non-empty `group`.", call. = FALSE)
}

read_json <- function(path) {
  if (!file.exists(path)) return(NULL)
  tryCatch(
    jsonlite::read_json(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
}

validate_timestamp <- function(x, field) {
  if (!is.character(x) || length(x) != 1L ||
      !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$", x)) {
    stop("Invalid `", field, "` timestamp.", call. = FALSE)
  }
}

validate_series <- function(payload, expected_id) {
  required <- c(
    "series_id", "name", "frequency", "source", "fetched_at",
    "last_observation", "observations"
  )
  if (!is.list(payload) || !all(required %in% names(payload))) {
    stop("Series ", expected_id, " is missing required metadata.", call. = FALSE)
  }
  if (!identical(payload$series_id, expected_id)) {
    stop("Unexpected series_id in ", expected_id, ".json.", call. = FALSE)
  }
  if (!is.character(payload$name) || length(payload$name) != 1L || !nzchar(payload$name) ||
      !is.character(payload$frequency) || length(payload$frequency) != 1L || !nzchar(payload$frequency) ||
      !identical(payload$source, "Banco Central de Chile")) {
    stop("Invalid metadata for series ", expected_id, ".", call. = FALSE)
  }
  validate_timestamp(payload$fetched_at, "fetched_at")

  observations <- payload$observations
  if (is.data.frame(observations)) {
    if (nrow(observations) == 0L || !all(c("date", "value") %in% names(observations))) {
      stop("Series ", expected_id, " has no observations.", call. = FALSE)
    }
    dates <- as.character(observations$date)
    values <- as.numeric(observations$value)
  } else if (is.list(observations) && length(observations) > 0L) {
    dates <- vapply(observations, function(x) x$date %||% "", character(1))
    values <- vapply(observations, function(x) x$value %||% NA_real_, numeric(1))
  } else {
    stop("Series ", expected_id, " has no observations.", call. = FALSE)
  }
  parsed_dates <- suppressWarnings(as.Date(dates, format = "%Y-%m-%d"))
  if (any(!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", dates)) || anyNA(parsed_dates)) {
    stop("Series ", expected_id, " has invalid dates.", call. = FALSE)
  }
  if (anyDuplicated(dates) || any(diff(parsed_dates) <= 0)) {
    stop("Series ", expected_id, " dates must be unique and ordered.", call. = FALSE)
  }
  if (anyNA(values) || any(!is.finite(values))) {
    stop("Series ", expected_id, " has invalid numeric values.", call. = FALSE)
  }
  if (!identical(payload$last_observation, tail(dates, 1L))) {
    stop("Series ", expected_id, " has an inconsistent last_observation.", call. = FALSE)
  }
  invisible(TRUE)
}

validate_repository <- function() {
  manifest <- read_json(manifest_path)
  if (is.null(manifest) || !all(c("updated_at", "series_count", "series") %in% names(manifest))) {
    stop("api/v1/manifest.json is missing or invalid.", call. = FALSE)
  }
  validate_timestamp(manifest$updated_at, "updated_at")
  if (!identical(as.integer(manifest$series_count), length(series_ids)) ||
      !setequal(names(manifest$series), series_ids)) {
    stop("Manifest and config/series.yml contain different series.", call. = FALSE)
  }

  for (id in series_ids) {
    entry <- manifest$series[[id]]
    if (is.null(entry$status) || !entry$status %in% c("ok", "stale", "error")) {
      stop("Invalid manifest status for ", id, ".", call. = FALSE)
    }
    if (identical(entry$status, "error")) {
      stop("Series ", id, " has no valid cached file.", call. = FALSE)
    }
    if (identical(entry$status, "stale")) {
      validate_timestamp(entry$last_attempt_at, "last_attempt_at")
      if (is.null(entry$error) || !nzchar(entry$error)) {
        stop("Stale series ", id, " needs a concise error.", call. = FALSE)
      }
    }

    expected_path <- paste0("series/", id, ".json")
    if (!identical(entry$path, expected_path)) {
      stop("Unexpected manifest path for ", id, ".", call. = FALSE)
    }
    payload <- read_json(file.path("api", "v1", entry$path))
    if (is.null(payload)) {
      stop("Missing or invalid JSON for ", id, ".", call. = FALSE)
    }
    validate_series(payload, id)
    if (!identical(entry$last_observation, payload$last_observation) ||
        !identical(as.integer(entry$observation_count), length(payload$observations)) ||
        !identical(entry$fetched_at, payload$fetched_at) ||
        !identical(entry$name, payload$name) ||
        !identical(entry$frequency, payload$frequency)) {
      stop("Manifest metadata does not match ", id, ".json.", call. = FALSE)
    }
  }

  message("Validated ", length(series_ids), " series and api/v1/manifest.json.")
  invisible(TRUE)
}

if (validate_only) {
  validate_repository()
  quit(save = "no", status = 0L)
}

token <- Sys.getenv("BCCH_TOKEN")
if (!nzchar(token)) {
  stop("BCCH_TOKEN is required to update data.", call. = FALSE)
}

dir.create(series_dir, recursive = TRUE, showWarnings = FALSE)
attempted_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
options(bcchr.verbose = FALSE)

metadata_result <- tryCatch(
  bcchr::describe_series(series_ids, token = token, verbose = FALSE),
  error = identity
)

sanitize_error <- function(error) {
  text <- conditionMessage(error)
  if (nzchar(token)) text <- gsub(token, "[redacted]", text, fixed = TRUE)
  substr(gsub("[\r\n]+", " ", text), 1L, 300L)
}

valid_previous <- function(path, id) {
  payload <- read_json(path)
  if (is.null(payload)) return(NULL)
  tryCatch({
    validate_series(payload, id)
    payload
  }, error = function(e) NULL)
}

manifest_series <- setNames(vector("list", length(series_ids)), series_ids)
hard_failures <- character()

for (index in seq_along(series_ids)) {
  id <- series_ids[[index]]
  path <- file.path(series_dir, paste0(id, ".json"))
  previous <- valid_previous(path, id)

  result <- tryCatch({
    if (inherits(metadata_result, "error")) stop(metadata_result)
    position <- match(id, metadata_result$series_id)
    if (is.na(position)) stop("No metadata returned by bcchr for ", id, ".")
    metadata <- metadata_result[position, , drop = FALSE]

    raw <- bcchr::get_series(id, token = token)
    dates <- suppressWarnings(as.Date(raw$date))
    values <- suppressWarnings(as.numeric(raw$value))
    keep <- !is.na(dates) & is.finite(values)
    observations <- data.frame(
      date = format(dates[keep], "%Y-%m-%d"),
      value = values[keep],
      stringsAsFactors = FALSE
    )
    observations <- observations[order(observations$date), , drop = FALSE]

    payload <- list(
      series_id = id,
      name = metadata$spanish_title[[1]],
      frequency = metadata$frequency[[1]],
      source = "Banco Central de Chile",
      fetched_at = attempted_at,
      last_observation = tail(observations$date, 1L),
      observations = observations
    )
    validate_series(payload, id)

    temporary <- tempfile(pattern = paste0(id, "-"), tmpdir = series_dir, fileext = ".tmp")
    jsonlite::write_json(
      payload, temporary, auto_unbox = TRUE, pretty = TRUE,
      digits = NA, na = "null"
    )
    written <- read_json(temporary)
    validate_series(written, id)
    if (!file.copy(temporary, path, overwrite = TRUE)) {
      stop("Could not replace ", path, ".")
    }
    unlink(temporary)

    list(payload = written, status = "ok")
  }, error = identity)

  if (inherits(result, "error")) {
    error_text <- sanitize_error(result)
    if (is.null(previous)) {
      hard_failures <- c(hard_failures, id)
      manifest_series[[id]] <- list(
        status = "error",
        last_attempt_at = attempted_at,
        error = error_text
      )
      message("ERROR  ", id, ": ", error_text)
    } else {
      manifest_series[[id]] <- list(
        path = paste0("series/", id, ".json"),
        name = previous$name,
        frequency = previous$frequency,
        last_observation = previous$last_observation,
        observation_count = length(previous$observations),
        fetched_at = previous$fetched_at,
        status = "stale",
        last_attempt_at = attempted_at,
        error = error_text
      )
      message("STALE  ", id, ": kept the last valid file (", error_text, ")")
    }
  } else {
    payload <- result$payload
    manifest_series[[id]] <- list(
      path = paste0("series/", id, ".json"),
      name = payload$name,
      frequency = payload$frequency,
      last_observation = payload$last_observation,
      observation_count = length(payload$observations),
      fetched_at = payload$fetched_at,
      status = "ok"
    )
    message("OK     ", id, ": ", length(payload$observations), " observations through ", payload$last_observation)
  }

  # Match bcchr's own batch throttle while retaining per-series error handling.
  if (index < length(series_ids) && index %% 5L == 0L) Sys.sleep(1)
}

manifest <- list(
  updated_at = attempted_at,
  series_count = length(series_ids),
  series = manifest_series
)
dir.create(dirname(manifest_path), recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(manifest, manifest_path, auto_unbox = TRUE, pretty = TRUE, digits = NA)

if (length(hard_failures) > 0L) {
  stop(
    "No valid cached file exists for: ", paste(hard_failures, collapse = ", "),
    call. = FALSE
  )
}
validate_repository()
