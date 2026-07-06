#!/usr/bin/env Rscript
# scripts/bootstrap-from-oldstats.R: one-shot builder for the frozen oldstats
# archive (2014 through April 2025). Fetches the four oldstats files and the
# Bioconductor roster, classifies each package origin (bioc vs cran), and writes
# bioconductor-oldstats.db. This is frozen: the daily update.R never rebuilds it.

options(timeout = 600)
suppressPackageStartupMessages({ library(DBI); library(RSQLite); library(jsonlite) })

.this_file <- function() {
  for (i in rev(seq_len(sys.nframe()))) {
    of <- sys.frame(i)$ofile
    if (!is.null(of) && nzchar(of)) return(normalizePath(of))
  }
  a <- commandArgs(FALSE)
  f <- sub("^--file=", "", grep("^--file=", a, value = TRUE))
  if (length(f) == 1L && nzchar(f)) return(normalizePath(f))
  NA_character_
}
.script_dir <- { tf <- .this_file(); if (!is.na(tf)) dirname(tf) else "scripts" }
if (!exists("category_tuples", mode = "function")) {
  source(file.path(.script_dir, "config.R"))
  source(file.path(.script_dir, "helpers.R"))
}

iso <- function(t) format(t, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")

run_oldstats_bootstrap <- function(io, out_dir) {
  dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
  roster <- io$bioc_roster()
  if (length(roster) == 0) {
    stop("empty Bioconductor roster; refusing to tag every package 'cran'")
  }
  cts <- category_tuples()
  monthly_parts <- list(); yearly_parts <- list()
  for (ct in cts) {
    lf <- io$fetch_oldstats(ct$dir, paste0(ct$prefix, "pkg_stats.tab"))
    if (is.null(lf) || !file.exists(lf)) {
      stop("could not fetch oldstats file for category ", ct$label)
    }
    text <- paste(readLines(lf, warn = FALSE), collapse = "\n")
    parsed <- parse_stats_tab(text, ct$label)
    sp <- split_monthly_yearly(parsed)
    m <- drop_future_placeholders(sp$monthly)
    if (nrow(m) > 0) m$origin <- classify_origin(m$package, roster)
    else m$origin <- character(0)
    y <- sp$yearly
    if (nrow(y) > 0) y$origin <- classify_origin(y$package, roster)
    else y$origin <- character(0)
    monthly_parts[[ct$label]] <- m
    yearly_parts[[ct$label]]  <- y
  }
  monthly <- do.call(rbind, monthly_parts); rownames(monthly) <- NULL
  yearly  <- do.call(rbind, yearly_parts);  rownames(yearly) <- NULL
  summary <- oldstats_rollup(monthly)

  export_oldstats_shard(file.path(out_dir, "bioconductor-oldstats.db"),
                        monthly, yearly, summary)

  oc <- as.list(table(factor(summary$origin, levels = c("bioc", "cran"))))
  list(
    generated_at   = iso(io$now()),
    frozen_through = if (nrow(monthly)) max(monthly$date) else NA_character_,
    rows           = nrow(monthly),
    packages       = nrow(summary),
    origin_counts  = list(bioc = as.integer(oc$bioc %||% 0L),
                          cran = as.integer(oc$cran %||% 0L)))
}

# ---------------------------------------------------------------------------
# Default (production) IO
# ---------------------------------------------------------------------------

with_retry <- function(expr, tries = 3L, wait = 3) {
  for (i in seq_len(tries)) {
    val <- tryCatch(force(expr), error = function(e) e)
    if (!inherits(val, "error")) return(val)
    if (i < tries) Sys.sleep(wait * i)
  }
  stop(val)
}

fetch_text <- function(url) {
  tmp <- tempfile()
  ok <- tryCatch({ with_retry(utils::download.file(url, tmp, quiet = TRUE)); TRUE },
                 error = function(e) FALSE)
  if (!ok || !file.exists(tmp)) return(NA_character_)
  paste(readLines(tmp, warn = FALSE), collapse = "\n")
}

default_oldstats_io <- function() {
  list(
    bioc_roster = function() {
      views <- unlist(lapply(BIOC_VIEWS_URLS, function(u) {
        t <- fetch_text(u); if (is.na(t)) character(0) else parse_views_packages(t)
      }))
      rem_txt <- fetch_text(BIOC_REMOVED_PACKAGES_URL)
      removed <- if (is.na(rem_txt)) character(0) else parse_removed_packages(rem_txt)
      sort(unique(c(views, removed)))
    },
    fetch_oldstats = function(dir, file) {
      for (base in OLDSTATS_CANDIDATE_BASES) {
        url  <- paste0(base, dir, "/", file)
        dest <- file.path(tempdir(), paste0("oldstats_", dir, "_", file))
        ok <- tryCatch({
          with_retry(utils::download.file(url, dest, mode = "wb", quiet = TRUE)); TRUE
        }, error = function(e) FALSE)
        if (ok && file.exists(dest) && file.size(dest) > 1000) return(dest)
      }
      NULL
    },
    now = function() Sys.time())
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  out_dir <- if (length(args) >= 1) args[1] else "out"
  block <- run_oldstats_bootstrap(default_oldstats_io(), out_dir)
  writeLines(jsonlite::toJSON(block, auto_unbox = TRUE, pretty = TRUE),
             file.path(out_dir, "oldstats-block.json"))
  cat("oldstats archive:", block$rows, "rows,",
      block$packages, "packages, frozen through", block$frozen_through, "\n")
}
