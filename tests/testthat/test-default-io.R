test_that("default_io resolve order prefers the canonical base then Wayback", {
  # resolve_source is network-driven, so we test the pure URL builders it uses.
  ct <- category_tuples()[[1]]  # software
  expect_equal(live_url(CANDIDATE_BASE_URLS[1], ct),
               "https://bioconductor.org/packages/stats/bioc/bioc_pkg_stats.tab")
  expect_match(wayback_raw_url(WAYBACK_SNAPSHOTS[["bioc"]], ct), "^http://web.archive.org/web/")
})
