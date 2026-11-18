# Repository instructions

## Scope

- This repository publishes a static cache/API of Banco Central de Chile and INE ENE series
  and a Quarto dashboard built from that cache.
- Treat `config/series.yml` and `config/indicators.yml` as the declarative BCCh inputs.
- Discover ENE histories from the published laboral-data catalog. Preserve its
  series keys, quality flags, rolling-quarter periods and source provenance.
- Treat `scripts/update_data.R` as the only generator of `api/v1/**`; do not edit
  generated JSON by hand. `catalog.json` contains all BCCh metadata and ENE records, while the
  manifest indexes only the published histories cached under `series/`.
- The dashboard must read local JSON and must not call the BCCh API directly.

## Data rules

- Write every history under `api/v1/series/` using two-space indentation and one
  key per line, including observations. Follow the official series header and ENE
  observation contract in the README. Keep ENE dimensions and upstream keys in
  the catalog. Publish ENE dates and coverage using the first day of the closing
  month; verify the rolling-quarter label when importing the central month from
  laboral-data. Consumers use the published date directly.
  Bump the ENE adapter version when cached histories must migrate.
- Preserve complete histories, ordered from oldest to newest, with unique dates
  and finite numeric values. Publish upstream ENE `sin_dato` as `value: null`; include
  `quality` only for numeric estimates marked `poco_fiable` or `no_fiable`.
- Derive highlighted indicators from the downloaded series without extra API
  requests, and write the manifest only after all other output succeeds.
- Preserve the versioned catalog contract and its editorial enrichment when
  changing metadata handling.
- Never print, commit, or embed `BCCH_TOKEN` or any other credential.
- Do not run the live updater unless the user explicitly asks for a BCCh download.

## Validation

- Validate the generated API with `python scripts/check_api.py`.
- Parse the updater with `Rscript -e "parse(file='scripts/update_data.R')"`.
- Render the dashboard with `quarto render dashboard/index.qmd`.
- Keep `.github/workflows/update-data.yml` consistent with the documented local
  validation and rendering flow.

## Git

- Use Conventional Commits, for example `feat:`, `fix:`, `docs:`, `refactor:`,
  `test:`, or `chore:`.
- Preserve unrelated user changes. Commit, push, and deploy only when explicitly
  requested.
