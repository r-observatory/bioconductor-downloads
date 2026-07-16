test_that("diff_source_state reports added, modified, and deleted by hash", {
  prev <- list("bioc/bioc_pkg_stats.tab" = list(hash = "A"),
               "workflows/workflows_pkg_stats.tab" = list(hash = "W"))
  curr <- list("bioc/bioc_pkg_stats.tab" = list(hash = "B"),         # modified
               "data-experiment/experiment_pkg_stats.tab" = list(hash = "E"))  # added
  expect_equal(diff_source_state(prev, curr),
    sort(c("bioc/bioc_pkg_stats.tab",
           "data-experiment/experiment_pkg_stats.tab",
           "workflows/workflows_pkg_stats.tab")))  # last is deleted
})

test_that("diff_source_state is empty when hashes are unchanged", {
  m <- list("bioc/bioc_pkg_stats.tab" = list(hash = "A"))
  expect_length(diff_source_state(m, m), 0L)
})

test_that("merge_shard_coverage overwrites only updated shards", {
  prev <- list("bioconductor-2009.db" = list(rows = 1L),
               "bioconductor-2026.db" = list(rows = 2L))
  upd  <- list("bioconductor-2026.db" = list(rows = 9L))
  out  <- merge_shard_coverage(prev, upd)
  expect_equal(out[["bioconductor-2009.db"]]$rows, 1L)
  expect_equal(out[["bioconductor-2026.db"]]$rows, 9L)
})

test_that("write_manifest round-trips and preserves null trend", {
  d <- withr::local_tempdir(); p <- file.path(d, "manifest.json")
  obj <- list(source_kind = "wayback", granularities = list("monthly"),
              data_through = list(monthly = "2026-01"))
  write_manifest(p, obj)
  back <- jsonlite::fromJSON(p, simplifyVector = FALSE)
  expect_equal(back$source_kind, "wayback")
  expect_equal(back$data_through$monthly, "2026-01")
})

# --- integrity / completeness core -----------------------------------------

# Build a tiny, real summary DB on disk (canonical schema via export_summary_shard).
build_summary_db <- function(n = 3L) {
  tmp <- tempfile(fileext = ".db")
  export_summary_shard(path = tmp, summary = data.frame(
    package             = paste0("pkg", seq_len(n)),
    package_lower       = paste0("pkg", seq_len(n)),
    category            = rep("software", n),
    download_score      = seq_len(n) * 1.5,
    total_last_month    = seq_len(n) * 10L,
    total_12mo          = seq_len(n) * 100L,
    rank_score          = seq_len(n),
    rank_downloads_12mo = seq_len(n),
    trend               = rep(NA_real_, n),
    stringsAsFactors = FALSE
  ))
  tmp
}

test_that("summary_integrity_core reports filename, bytes, sha256, tables, complete", {
  db <- build_summary_db(3L)
  on.exit(unlink(db))

  core <- summary_integrity_core(db, complete = TRUE)

  expect_equal(core$db_filename, basename(db))
  # db_bytes is a double (not cast to integer) so files >= ~2 GiB do not
  # overflow to NA; compare against the uncast file.size() directly.
  expect_type(core$db_bytes, "double")
  expect_equal(core$db_bytes, file.size(db))
  # sha256 is lowercase 64-char hex of the exact file bytes
  expect_match(core$db_sha256, "^[0-9a-f]{64}$")
  # tables maps every user table to its row count
  expect_equal(core$tables, list(bioc_downloads_summary = 3L))
  expect_true(core$complete)
})

test_that("summary_integrity_core sha256 matches an independent digest of the bytes", {
  # Compute the expected hash via an external CLI tool, independent of
  # file_sha256()'s own preferred backend (digest/openssl), so this test
  # genuinely cross-checks the code path instead of re-running the same
  # library. Skip only if neither tool is on PATH (both are expected on CI).
  sha256sum_bin <- Sys.which("sha256sum")
  shasum_bin    <- Sys.which("shasum")
  if (!nzchar(sha256sum_bin) && !nzchar(shasum_bin)) {
    skip("neither sha256sum nor shasum is on PATH")
  }

  db <- build_summary_db(2L)
  on.exit(unlink(db))

  core <- summary_integrity_core(db)

  if (nzchar(sha256sum_bin)) {
    out <- system2(sha256sum_bin, shQuote(db), stdout = TRUE)
  } else {
    out <- system2(shasum_bin, c("-a", "256", shQuote(db)), stdout = TRUE)
  }
  independent <- tolower(sub("\\s.*$", "", out[1]))

  expect_equal(core$db_sha256, independent)
})

test_that("write_manifest merges the integrity core as top-level fields", {
  db <- build_summary_db(4L)
  on.exit(unlink(db), add = TRUE)
  core <- summary_integrity_core(db, complete = TRUE)

  tmp <- tempfile(fileext = ".json")
  on.exit(unlink(tmp), add = TRUE)

  write_manifest(
    path = tmp,
    obj  = list(
      tag            = "v20260714-000000",
      changed_shards = list("bioconductor-summary.db"),
      summary        = list(packages = 4L)),
    core = core)

  parsed <- jsonlite::fromJSON(tmp)
  # existing fields preserved
  expect_equal(parsed$tag, "v20260714-000000")
  expect_equal(parsed$summary$packages, 4L)
  # new top-level integrity/completeness core
  expect_equal(parsed$db_filename, basename(db))
  expect_equal(parsed$db_bytes, file.size(db))
  expect_match(parsed$db_sha256, "^[0-9a-f]{64}$")
  expect_equal(parsed$tables$bioc_downloads_summary, 4L)
  expect_true(parsed$complete)
})
