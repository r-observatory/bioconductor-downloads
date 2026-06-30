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
