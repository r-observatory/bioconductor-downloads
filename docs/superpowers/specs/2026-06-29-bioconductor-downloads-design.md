# bioconductor-downloads Pipeline Design

**Date:** 2026-06-29
**Status:** Approved design, awaiting review before implementation planning
**Repo (new):** `r-observatory/bioconductor-downloads`
**Source:** Bioconductor download statistics (`.tab` files under `/packages/stats/`). The canonical endpoint is currently in outage, so history is bootstrapped from the Internet Archive.
**Sibling templates:** `r-observatory/cran-downloads` (reference) and `r-observatory/r2u-downloads` (freshest sibling)

## Goal

Add a new producer pipeline to the r-observatory org that turns Bioconductor's monthly per-package download statistics into year-sharded SQLite on a rolling `current` GitHub release. This is the same distribution contract as `cran-downloads` and `r2u-downloads`, so downstream consumers (the `data` merger, the viewer) can adopt it with a one-line allowlist change later.

The pipeline covers all four Bioconductor stat categories (software, data-annotation, data-experiment, workflows), preserves both of Bioconductor's published metrics (distinct IPs and downloads), and replicates Bioconductor's official download score. Granularity is monthly, the finest resolution Bioconductor publishes (see *Granularity*). The architecture leaves a clean, near-zero-cost door open for a future daily extension without redesign, but builds no daily plumbing now.

## Source data reality (observed, not inferred)

Verified by direct `curl` and Wayback inspection, and by reading the upstream generator ([`Bioconductor/download_stats`](https://github.com/Bioconductor/download_stats)).

### Distribution model

Bioconductor publishes per-package download stats only as static tab-separated `.tab` files over HTTPS (no auth, no JSON or REST API). This is the same "scrape a static source" shape as the other r-observatory pipelines. There is one aggregate "all packages, all months" TSV per category:

| Category | Dir | Aggregate file | URL |
|---|---|---|---|
| software | `bioc` | `bioc_pkg_stats.tab` | `…/packages/stats/bioc/bioc_pkg_stats.tab` |
| data-annotation | `data-annotation` | `annotation_pkg_stats.tab` | `…/packages/stats/data-annotation/annotation_pkg_stats.tab` |
| data-experiment | `data-experiment` | `experiment_pkg_stats.tab` | `…/packages/stats/data-experiment/experiment_pkg_stats.tab` |
| workflows | `workflows` | `workflows_pkg_stats.tab` | `…/packages/stats/workflows/workflows_pkg_stats.tab` |

The filename quirk must be hardcoded as `(dir, prefix, label)` tuples because it is not derivable: the `data-` prefix is dropped in two of the four filenames (`data-annotation` uses `annotation_`, `data-experiment` uses `experiment_`), while `bioc` and `workflows` match their dir.

### Schema (exact, tab-separated, LF, no trailing newline)

The aggregate per-category file has 5 columns, header exactly:

```
Package<TAB>Year<TAB>Month<TAB>Nb_of_distinct_IPs<TAB>Nb_of_downloads
```

Verbatim sample (`bioc_pkg_stats.tab`):

```
a4	2026	Jan	163	239
a4	2026	all	163	239
a4	2025	all	2611	6030
```

- `Package`: case-sensitive Bioconductor name (`a4`, `a4Base`, `DESeq2`, `limma`). The aggregate spans historical and removed packages, so it is a superset of the current release.
- `Year`: 4-digit integer.
- `Month`: one of `Jan` through `Dec`, plus a special literal `all` that is the year's aggregate row, appearing after the 12 month rows of each `(Package, Year)` block.
- `Nb_of_distinct_IPs`: unique source IPs that hit the package that month.
- `Nb_of_downloads`: raw download or hit count that month, always at least the distinct-IP count.

Per-package files (`<Pkg>/<Pkg>_stats.tab`, `<Pkg>_<YEAR>_stats.tab`) drop the `Package` column (4 columns; package implied by path). A separate `bioc_pkg_scores.tab` (`Package<TAB>Download_score`) holds the precomputed score. No version, OS, arch, or country column exists anywhere, because Bioconductor stats are a single combined, version-agnostic figure. The `pkgType` and `Date` columns seen in `BiocPkgTools` output are added client-side, not present in the bytes.

### The two metrics, and a non-additivity hazard

Bioconductor reports two numbers per package per month, which drives the schema:

- `Nb_of_downloads` is additive across months. The yearly `all` row download value equals the sum of the 12 monthly values (verified arithmetically on `limma` 2024: `all = 756903 = sum of months`).
- `Nb_of_distinct_IPs` is NOT additive. The yearly `all` distinct-IP value is de-duplicated across the whole year and is smaller than the sum of the months (verified on `limma` 2024: `all = 276697 < 404053 = sum of monthly distinct-IPs`). Never sum distinct-IPs across periods; take the `all` row for a yearly figure.

Bioconductor's headline ranking is the download score, defined verbatim on the stats index (confirmed on a live mirror) as "the average number of distinct IPs that 'hit' the package each month for the last 12 months (not counting the current month)." It is built on distinct IPs, averaged over a trailing 12 months, excluding the current month.

### Cadence, history, current-period shape

- Cadence: the files are regenerated twice weekly (Tuesday and Friday) per the upstream `download_stats` crontab, not monthly. A daily change-gated cron fits (expects real changes about twice a week), but change-detection must be HTTP-level (`Last-Modified`, `ETag`, content-hash) because the source is not a git repo (unlike r2u's blob-SHA diff).
- History: monthly, back to 2009 for software. Other categories start later (workflows around 2013 to 2014).
- Current-period shape (this matters for ingest): each current-year block pre-lists all 12 months. The in-progress month carries partial month-to-date counts, future months of the current year are explicit zero rows, and the per-year `all` row sums the year. The pipeline must distinguish a genuine past zero from a not-yet-happened future zero (drop current-year months strictly after the latest real-data month) and re-ingest the current month every run because it keeps accumulating.

### Granularity: monthly is the finest PUBLIC resolution (confirmed in generator code)

Reading `Bioconductor/download_stats`: `makeDownloadDbs.py` parses raw Apache, Squid, and CloudFront access logs into an `access_log` table that does carry a `day_month_year` field (day resolution) and per-IP rows. But the published extraction (`stats_utils.py`) runs `SELECT month_year, count(*) ... GROUP BY month_year`, and `stats_config.getLastMonths(12)` windows the score by month. So day-level data exists only internally on Bioconductor's servers (private S3 and access-log buckets via `get_s3_logs.py` and `get_billing_logs.py`); nothing daily is exposed. Every public tool (`BiocPkgTools`, `dlstats`, the website) is monthly because that is all the source emits. By contrast, CRAN's daily cranlogs exists only because Posit publishes its mirror's daily logs; Bioconductor made the opposite choice and leads with a distinct-IP metric that inherently needs a time window.

### Live-source outage (the reason for the dual-source design)

As of late June 2026 the canonical `/packages/stats/` tree is down:

| URL | Status |
|---|---|
| `…/packages/stats/` | 302 to `/about/removed-packages/` (a generic deprecated-*packages* list, not a stats notice; a misconfigured catch-all) |
| `…/packages/stats/<cat>/<file>.tab` | 404 (CloudFront error page) |
| `…/packages/oldstats/bioc/bioc_pkg_stats.tab` | 200, but frozen at 2025-04-15 (post-April rows are zero placeholders) |
| `stats.bioconductor.org` (intended replacement host) | DNS NXDOMAIN |

Investigation verdict (multi-source, adversarially verified):

- The legacy path is deliberately retired (purpose-built redirect plus a clean 404), and `BiocPkgTools::biocDownloadStats()`, which hardcodes that URL, is broken today.
- The data service is mid-migration, not abandoned. Official word: a 2026-06-17 bioc-devel email from Lori Kern (Bioconductor Core Team) states "The download stats are currently unavailable until further notice. We are investigating a resolution." A named, actively-developed replacement, [`Bioconductor/bio-web-stats`](https://github.com/Bioconductor/bio-web-stats) (last push 2026-06-26), is a WSGI service covering 2009 to present whose `.tab` and `.txt` responses are, per its README, "byte-for-byte identical to the prior system" and reported "on www.bioconductor.org." So the canonical `/packages/stats/` path will most likely be restored rather than replaced with a new path.
- Timeline: the live feed advanced through January 2026 (last Wayback capture, about 10 MB, real data); the BioC 3.23 redesign landed 2026-04-29; the status monitor flagged the failure 2026-06-10; the official email was 2026-06-17. Break window: late January to June 2026, around the spring redesign.
- No live source of fresh (post-April-2025) data exists right now. The only recoverable fresh data is the Internet Archive snapshot of the canonical `.tab` through about January 2026. The `oldstats` tree is a stale April-2025 archive, strictly worse, and must NOT be used as a live source: its post-April rows are zeros that would silently poison rankings.

## The core difference from the sibling pipelines

| Dimension | cranlogs (`cran-downloads`) | r2u-logs (`r2u-downloads`) | Bioconductor (this pipeline) |
|---|---|---|---|
| Delivery | HTTP JSON API | git repo of `.csv.zst` | static `.tab` over HTTPS (currently via Internet Archive) |
| Granularity | daily | daily (from raw logs) | monthly (source-imposed) |
| Aggregation | pre-aggregated | raw per-request; we aggregate | pre-aggregated (monthly) |
| Metric(s) | `count` | `count` (raw fetches) | two: `n_distinct_ips` and `n_downloads` |
| Change detection | n/a (fetch by date) | git blob SHA | HTTP `Last-Modified` / `ETag` / hash |
| ETL engine | none (API gives counts) | DuckDB over millions of raw rows | base R `read.delim` (files at most 17 MB) |
| Extra dims | none | `dist`, `arch`, repo | `category` (4) |
| Names | canonical CRAN case | lowercased Debian token | canonical Bioc case (already canonical) |
| Headline | downloads | downloads | distinct-IP download score |

The ETL is simpler than r2u (no decompression, no per-request dedup, no DuckDB). The novelty is the dual-source availability gate, the two-metric and non-additive handling, and the monthly windowing.

## Decisions (locked with the user)

| # | Decision | Choice |
|---|---|---|
| 1 | Repo name | `bioconductor-downloads` (matches the `<source>-downloads` convention) |
| 2 | Sharding | Year shards plus `-recent.db`, `-summary.db`, and `manifest.json` (strict template parity) |
| 3 | Package key | Canonical Bioconductor case (`DESeq2`, `limma`); a lowercased `package_lower` helper column for case-insensitive joins |
| 4 | Scope | All four categories, carried as a `category` dimension (software-only is a filter) |
| 5 | Metrics | Keep both `n_distinct_ips` and `n_downloads`; replicate the official `download_score` |
| 6 | Build strategy | Full rebuild on any source change (data is tiny); year shards are an output format, not incremental machinery |
| 7 | Data source now | Bootstrap the monthly archive from the Internet Archive (2009 through about January 2026); live ingestion on standby, auto-flips when the canonical endpoint returns |
| 8 | Granularity | Monthly now; architect a near-zero-cost daily door (reserved table and shard namespace), build no daily code |

## Granularity and the daily door (designed-in, not built)

Monthly is the canonical product. To allow a future daily extension without redesign or migration, the following are reserved now at no build cost:

- Granularity-explicit table names: `bioc_downloads_monthly` and `bioc_downloads_yearly`. A future `bioc_downloads_daily` coexists with no collision.
- Real ISO `date` columns everywhere (monthly uses first-of-month `YYYY-MM-01`), so a daily table's per-day `date` is schema-compatible and merges cleanly.
- A reserved shard family `bioconductor-daily-YYYY.db`, separate from the small monthly shards (daily would be roughly 1000 times larger, like cran-downloads, so it must not bloat the monthly artifacts).
- Source-adapter factoring (below): each source is a pure parser plus a descriptor; the run loop iterates configured sources. A daily adapter slots in beside the monthly ones.
- `manifest.json` carries a `granularities` array (now `["monthly"]`) and a per-granularity `data_through`, so consumers and the merger discover what exists.

A future daily table would likely carry `n_downloads` (additive, day-meaningful) and optionally a daily distinct-IP count; the monthly `download_score` remains the canonical IP metric, because daily distinct-IPs are non-additive and not summable to the monthly figure. Daily ingestion is out of scope here and gets its own design only if a daily source ever materializes.

## Architecture

### Distribution contract (rolling `current` release)

Title "Bioconductor Downloads (rolling)". Assets, with tables namespaced `bioc_` so the `data` merger can ingest them alongside cran and r2u tables without collision:

```
releases/current/
├── bioconductor-recent.db    ← last 36 months of bioc_downloads_monthly + the summary table
├── bioconductor-2009.db      ← per-year monthly + yearly tables
├── bioconductor-2010.db
│   …
├── bioconductor-2026.db
├── bioconductor-summary.db   ← ONLY bioc_downloads_summary (small; for the data merger)
└── manifest.json             ← run report + persistent state + availability/provenance
   (reserved for the future daily extension: bioconductor-daily-YYYY.db, NOT produced now)
```

Each run uploads only changed assets via `gh release upload current … --clobber`, with `manifest.json` uploaded LAST (a crash before it leaves the prior state authoritative, forcing a safe re-derive next run). Stable URLs look like `https://github.com/r-observatory/bioconductor-downloads/releases/download/current/bioconductor-2025.db`.

### Schema

`bioc_downloads_monthly`, present in each `bioconductor-YYYY.db` and in `bioconductor-recent.db`:

| Column | Type | Notes |
|---|---|---|
| `package` | TEXT | canonical Bioc name (PK part 1) |
| `category` | TEXT | `software`, `data-annotation`, `data-experiment`, or `workflows` (PK part 2) |
| `date` | TEXT | `YYYY-MM-01`, first-of-month (PK part 3), monthly granularity |
| `n_distinct_ips` | INTEGER | distinct IPs that month |
| `n_downloads` | INTEGER | downloads that month |

PK `(package, category, date)`; index on `date` and on `package`. Future-month zero placeholders are dropped; genuine past zeros are kept.

`bioc_downloads_yearly`, present in each `bioconductor-YYYY.db`. This holds the non-additive yearly distinct-IPs taken verbatim from the `all` row, never recomputed:

| Column | Type | Notes |
|---|---|---|
| `package` | TEXT | (PK part 1) |
| `category` | TEXT | (PK part 2) |
| `year` | INTEGER | (PK part 3) |
| `n_distinct_ips_year` | INTEGER | from the `all` row, year-unique, not a sum of months |
| `n_downloads_year` | INTEGER | from the `all` row, equals the sum of the year's months |

`bioc_downloads_summary`, present in `bioconductor-recent.db` and `bioconductor-summary.db`, rebuilt each run, anchored to the latest complete month in the data (not "today"), computed in SQL:

| Column | Type | Notes |
|---|---|---|
| `package` | TEXT | canonical name (PK part 1) |
| `package_lower` | TEXT | lowercased helper for case-insensitive joins |
| `category` | TEXT | the package's category (PK part 2) |
| `download_score` | REAL | official metric: mean monthly `n_distinct_ips` over the trailing 12 complete months ending at the anchor, excluding the current partial month |
| `total_last_month` | INTEGER | `n_downloads` in the latest complete month |
| `total_12mo` | INTEGER | `n_downloads` summed over the trailing 12 complete months (additive) |
| `rank_score` | INTEGER | rank by `download_score` within `category` (Bioconductor's headline order) |
| `rank_downloads_12mo` | INTEGER | rank by `total_12mo` within `category` |
| `trend` | REAL | percent change: last-3-complete-months downloads vs the prior 3; `NULL` when the prior window is 0 |

There is deliberately no "12-month distinct-IP total" column. Distinct IPs are non-additive across months, so a 12-month sum would overcount. The `download_score` (an average) is the honest distinct-IP summary, exactly as Bioconductor does it.

On window anchoring: because the source lags and the current month is partial, all summary windows anchor to the latest complete month present in the data (the latest month strictly before the current calendar month, or equivalently the latest fully-populated month). This is documented in the README.

Published shards use `PRAGMA journal_mode=DELETE` (no WAL) and are `VACUUM`ed at export.

### Source adapters, availability gate, change detection

A source adapter is `{ kind, fetch(category) -> raw_bytes or NULL, descriptor }`. Two adapters now:

- `live`: probes an ordered list of candidate base URLs and uses the first that serves valid `.tab` data for the categories:
  1. `https://bioconductor.org/packages/stats/` (canonical; most likely restored)
  2. `https://stats.bioconductor.org/packages/stats/` (replacement host, if it becomes public)
  Each candidate is probed per category file; "valid" means HTTP 200 plus a parseable header plus a data month newer than the archive. It uses conditional GET (`If-None-Match`, `If-Modified-Since`).
- `wayback`: fetches the best Internet Archive raw snapshot per category (`http://web.archive.org/web/<ts>id_/<canonical-url>`), for example software `20260126211628` (data through about January 2026). One snapshot per category, pinned in config.

Availability gate, at the start of every run:

| State | Condition | Action |
|---|---|---|
| `live` | a candidate base URL serves fresh data | ingest live (full-history files supersede the archive) |
| `frozen` | no live candidate AND a release already exists | heartbeat: bump `last_checked`, upload only `manifest.json` |
| `wayback` (bootstrap) | no live candidate AND no release yet | bootstrap the archive from Wayback snapshots |

Change detection is per category file via the stored `ETag`, `Last-Modified`, and `sha256` in the manifest (HTTP-level, no git). The `oldstats` tree is never used as a source.

### `manifest.json` (run report, persistent state, provenance)

```jsonc
{
  "tag": "vYYYYMMDD-HHMMSS",
  "generated_at": "2026-06-29T06:00:11Z",
  "last_checked": "2026-06-29T06:00:11Z",   // bumped EVERY run (heartbeat for the refresh page)
  "last_changed": "2026-06-29T06:00:09Z",   // last run that ingested new/changed data
  "source_kind": "wayback",                  // "live" | "wayback" | "frozen" this run
  "live_available": false,
  "candidate_base_urls": [
    "https://bioconductor.org/packages/stats/",
    "https://stats.bioconductor.org/packages/stats/"
  ],
  "granularities": ["monthly"],              // reserves the daily door
  "data_through": { "monthly": "2026-01" },  // latest complete month per granularity
  "source_files": {                          // per-category, for diffing next run
    "bioc/bioc_pkg_stats.tab":                  { "etag": "\"a1b2…\"", "last_modified": "Mon, 26 Jan 2026 21:16:28 GMT", "sha256": "9f3c…", "via": "wayback:20260126211628" },
    "data-annotation/annotation_pkg_stats.tab": { "etag": "\"c3d4…\"", "last_modified": "Mon, 26 Jan 2026 21:18:02 GMT", "sha256": "1a77…", "via": "wayback:20260126…" },
    "data-experiment/experiment_pkg_stats.tab": { "etag": "\"e5f6…\"", "last_modified": "Mon, 26 Jan 2026 21:19:44 GMT", "sha256": "be20…", "via": "wayback:20260126…" },
    "workflows/workflows_pkg_stats.tab":        { "etag": "\"0789…\"", "last_modified": "Mon, 26 Jan 2026 21:20:51 GMT", "sha256": "44ad…", "via": "wayback:20260126…" }
  },
  "changed_shards": ["bioconductor-2026.db", "bioconductor-recent.db", "bioconductor-summary.db"],
  "shards": {                                // persistent per-year coverage; carried forward
    "bioconductor-2009.db": { "rows": 12345, "date_min": "2009-01-01", "date_max": "2009-12-01" },
    "bioconductor-2026.db": { "rows": 6789,  "date_min": "2026-01-01", "date_max": "2026-01-01" }
  },
  "summary": { "categories": ["software","data-annotation","data-experiment","workflows"],
               "packages": 6198, "source_rows_read": 1007900 }
}
```

### Daily run logic (`scripts/update.R` computes, the workflow uploads)

```
1. Pull manifest.json from the `current` release (tiny). Absent -> bootstrap.
2. Availability gate: probe candidate base URLs for the 4 category files -> source_kind.
     - frozen (no live, release exists) -> write manifest with last_checked=now,
       everything else carried forward; exit. (Workflow uploads ONLY manifest.json.)
3. For the chosen source, conditional-GET / hash each category file -> changed set.
     - nothing changed -> heartbeat (as above).
4. On any change -> FULL REBUILD (data is small; simplest and idempotent):
     a. parse all four category files (by header name, never by position);
     b. split monthly rows vs `all` rows; drop future-month zero placeholders;
        map Month -> YYYY-MM-01; validate n_downloads >= n_distinct_ips (log violations);
     c. write every bioconductor-YYYY.db (monthly + yearly tables), VACUUM;
     d. assemble the working store -> bioconductor-recent.db (last 36 months + summary);
     e. compute bioc_downloads_summary in SQL (score, totals, ranks, trend anchored to the
        latest complete month) -> bioconductor-summary.db.
5. Write manifest.json: source_files (with `via`), source_kind, granularities, data_through,
   changed_shards, shards, summary; last_checked = last_changed = now.
6. (Workflow) upload changed_shards, then manifest.json LAST.
```

When the live endpoint returns, `source_kind` auto-flips from `wayback` to `live` on the next daily run, the full-history live files supersede the archive, and any January-2026-to-relaunch gap is filled automatically if upstream backfilled it (the new system claims 2009-to-present coverage).

### ETL / cleaning (pure helpers, unit-tested against junk fixtures)

- Category tuples are hardcoded: `("bioc","bioc_","software")`, `("data-annotation","annotation_","data-annotation")`, `("data-experiment","experiment_","data-experiment")`, `("workflows","workflows_","workflows")`.
- Parse by header name (`read.delim`, `sep="\t"`, `colClasses` set after reading the header), never by column position.
- Split `Month` in `{Jan..Dec}` (monthly) vs `Month == "all"` (yearly).
- Drop future-month placeholders: a current-year monthly row after the latest real-data month with both metrics `0`. Keep genuine past zeros.
- Map the month abbreviation to `YYYY-MM-01`.
- Yearly: take the `all` row's distinct-IPs (year-unique) and downloads verbatim.
- Validate `n_downloads >= n_distinct_ips`; log offenders (a data-quality canary).
- No host union, no dedup (already aggregated). Files are at most 17 MB, so base R is sufficient and there is no DuckDB.

### Functions

Pure (in `scripts/helpers.R`, unit-tested):

- `category_tuples()` returns the four `(dir, prefix, label)` tuples
- `parse_stats_tab(text)` returns a tidy long data frame `{package, year, month_token, n_distinct_ips, n_downloads}`
- `split_monthly_yearly(df)` returns `list(monthly, yearly)` (segregates `all` rows)
- `drop_future_placeholders(monthly, anchor)` returns monthly minus not-yet-happened zeros
- `month_to_date(year, token)` returns `YYYY-MM-01`
- `summary_sql(anchor_month)` returns the SQLite window-function summary query string
- `download_score_sql(anchor_month)` and `trend_sql(anchor_month)` (or folded into `summary_sql`)
- `extract_recent_rows(con, anchor, months = 36)` and `extract_year_rows(con, year)`
- `diff_source_state(prev_map, curr_map)` returns the changed category paths
- `export_shard(path, monthly, yearly)`, `export_summary_shard(path, summary)`, `write_manifest(...)`

Impure (in `update.R` or a thin IO module):

- `probe_live(candidate_base_urls)` returns the first base URL serving valid data, or `NULL`
- `fetch_category(source, dir, file)` (conditional GET; Wayback raw URL)
- `gh_release_download()` and `gh` release helpers

### Repo layout (sibling of cran-downloads / r2u-downloads)

```
bioconductor-downloads/
├── README.md                 # intro, attribution, schema, example queries, caveats, outage note
├── LICENSE                   # MIT (pipeline code)
├── .gitignore                # *.tab, *.db, out/, tmp/, .Rhistory, .RData
├── last-updated.txt
├── scripts/
│   ├── update.R              # daily availability+change-gated producer (computes; never uploads)
│   ├── helpers.R             # pure, unit-tested functions
│   ├── config.R              # category tuples, candidate base URLs, pinned Wayback snapshots, windows
│   └── bootstrap-from-wayback.R  # explicit one-shot full archive build (update.R also self-bootstraps)
├── tests/
│   ├── testthat.R
│   └── testthat/
│       ├── helper-setup.R
│       ├── fixtures/         # tiny real-format .tab incl. an `all` row, a future-zero row, all four
│       │                     #   categories, a known-score case, a downloads<ips violation
│       ├── test-parse-stats-tab.R
│       ├── test-split-monthly-yearly.R
│       ├── test-drop-future-placeholders.R
│       ├── test-yearly-distinct-ips.R     # takes `all` row; non-additive
│       ├── test-summary-score.R           # score = 12mo avg distinct IPs excl current
│       ├── test-diff-source-state.R
│       ├── test-export-shard.R
│       └── test-manifest.R
├── .github/workflows/
│   ├── update.yml            # cron "0 6 * * *" + workflow_dispatch
│   └── test.yml              # PR + push to main
└── out/                      # build dir (gitignored)
```

R dependencies: `RSQLite`, `DBI`, `jsonlite`, `testthat`, `curl` (conditional GET). No DuckDB.

### Workflows

`update.yml`: `cron: "0 6 * * *"` plus `workflow_dispatch`; `permissions: contents: write`; `concurrency: bioconductor-downloads-update` (no cancel-in-progress); `timeout-minutes: 60`; `setup-r` (release, `use-public-rspm: true`) plus deps; run tests, then `Rscript scripts/update.R out/`; create the `current` release if absent (static notes), upload `changed_shards` then `manifest.json` last; commit `last-updated.txt`. The 06:00 UTC cron keeps it ahead of the `data` repo's roughly 08:00 merge, matching the sibling pipelines.

`test.yml`: PR plus push to `main`; installs the same deps; `Rscript tests/testthat.R`.

## Semantic caveats (must be prominent in the README)

- Monthly only. Bioconductor publishes no daily per-package counts; this is a source constraint, not a pipeline choice.
- Two metrics. `n_downloads` (raw, additive) and `n_distinct_ips` (a partial repeat and bot dampener, non-additive across time). The download score (12-month average of distinct IPs, excluding the current month) is Bioconductor's headline.
- Not comparable to `cran-downloads` (daily, one mirror, version and OS split) or `r2u-downloads` (raw apt fetches). Different populations and methods; do not compare magnitudes.
- Version-agnostic, all package file types combined, no OS, arch, or country breakdown.
- Historical data reconstructed from the Internet Archive during the 2026 Bioconductor stats outage; coverage is complete through about January 2026, with a gap until the canonical endpoint is restored. `source_kind` and `data_through` in `manifest.json` expose exactly which months are present and where they came from.
- Package names are the canonical Bioconductor case; `package_lower` aids case-insensitive joins.

## Edge cases

- Cold start (no release): every category file is "new", so bootstrap from Wayback. `bootstrap-from-wayback.R` is the explicit entry point, and `update.R` produces the same result against an empty release.
- Outage persists (no live, release exists): the daily heartbeat refreshes `last_checked` only, with no shard churn and no false freshness signal.
- Live endpoint returns: the next run auto-detects a valid candidate, flips to `live`, and rebuilds from the full-history live files (which supersede the archive); a backfilled gap fills itself.
- Live returns at a new path or host: add it to `candidate_base_urls` in `config.R` (a one-line change), with no code change.
- `all` row missing or malformed for a `(package, year)`: yearly distinct-IPs for that cell is `NULL` (we never recompute it from months); monthly rows are unaffected.
- `n_downloads < n_distinct_ips` (should be impossible): the row is kept and logged as a data-quality canary.
- A new future category added by Bioconductor: unknown categories are ignored with a log line until a tuple is added (kept explicit by design).
- Crash mid-run: the prior release is intact (manifest uploaded last); shards are atomic per asset; the next run re-derives (idempotent full rebuild).

## Out of scope (explicit follow-on work)

1. Future daily ingestion, only if a daily Bioconductor source ever materializes (raw logs or a new endpoint). It gets its own design; it would add a `daily` source adapter, a `bioc_downloads_daily` table, and a `bioconductor-daily-YYYY.db` shard family, leaving the monthly path untouched.
2. A data-refresh page on the viewer, consuming the `manifest.json` freshness and provenance fields (`last_checked`, `last_changed`, `source_kind`, `data_through`) this pipeline already emits.
3. Wiring `bioconductor-summary.db` into the `data` merger: add it to the merger's source allowlist; tables are pre-namespaced (`bioc_*`) for exactly this.
4. Banking `bioc_pkg_scores.tab` (the precomputed official score) as a cross-check column. Optional; our `download_score` is computed independently.

## Testing strategy

testthat 3e, self-sufficient tests, `withr` for cleanup. Fixtures are tiny real-format `.tab` files including the known hazards: an `all` yearly row (asserting non-additive distinct-IPs are taken, not summed), a future-month zero placeholder (asserting it is dropped while a genuine past zero is kept), all four categories including the `annotation_` and `experiment_` filename quirk, a known-`download_score` case (asserting the 12-month distinct-IP average excludes the current month), and a `downloads < distinct_ips` violation. Unit tests assert: tab parsing by header; the monthly and yearly split; future-placeholder dropping; yearly distinct-IP extraction; summary score, totals, ranks, and trend anchored to `MAX(date)` with `trend` NULL-on-zero; source-state diffing (add and modify); shard and summary export schema; manifest shape including `source_kind`, `granularities`, `data_through`, and carry-forward `shards`. CI runs tests before every produce step.

## Open items to confirm during implementation planning

1. Recent window of 36 months (vs 24 or 60). Confirm.
2. `trend` as last-3-complete-months vs the prior 3. Confirm against month-over-month or year-over-year.
3. The pinned Wayback snapshot timestamp per category. Software `20260126211628` is known; pin the freshest good snapshot for data-annotation, data-experiment, and workflows.
4. `download_score` rounding and format, to match Bioconductor's published score (for a future cross-check against `bioc_pkg_scores.tab`).
5. Candidate base-URL order and the exact "valid live data" probe predicate (status plus header plus a data month newer than the archive).
6. Cold-start runtime (four files, at most about 30 MB total) vs the CI budget. Expected trivial; validate on the first `workflow_dispatch`.
