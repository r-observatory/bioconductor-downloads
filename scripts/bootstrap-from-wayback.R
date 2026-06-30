#!/usr/bin/env Rscript
# scripts/bootstrap-from-wayback.R: explicit one-shot full build from the pinned
# Internet Archive snapshots, used while the canonical endpoint is in outage.
# Equivalent to update.R against an empty release with force_full = TRUE.
.dir <- dirname(sub("^--file=", "", grep("^--file=",
  commandArgs(FALSE), value = TRUE))[1])
source(file.path(.dir, "config.R"))
source(file.path(.dir, "helpers.R"))
source(file.path(.dir, "update.R"))

out_dir <- { a <- commandArgs(trailingOnly = TRUE); if (length(a) >= 1) a[1] else "out" }
res <- run_update(default_io(), out_dir, force_full = TRUE)
cat("Bootstrapped shards:", paste(res$changed_shards, collapse = ", "), "\n")
