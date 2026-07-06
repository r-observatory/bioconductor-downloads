test_that("oldstats_rollup summarizes per package with an interior zero month", {
  monthly <- data.frame(
    package = "AACR", category = "software",
    date = c("2015-01-01", "2015-02-01", "2015-03-01"),
    origin = "bioc",
    n_distinct_ips = c(5L, 0L, 8L),
    n_downloads = c(10L, 0L, 12L), stringsAsFactors = FALSE)
  r <- oldstats_rollup(monthly)
  expect_equal(nrow(r), 1L)
  expect_equal(r$total_downloads, 22L)
  expect_equal(r$months_active, 2L)              # Feb 2015 had 0 downloads
  expect_equal(r$first_month, "2015-01-01")
  expect_equal(r$last_month, "2015-03-01")
  expect_equal(r$origin, "bioc")
})

test_that("oldstats_rollup returns an empty frame with the right columns for no rows", {
  empty <- data.frame(package = character(0), category = character(0),
    date = character(0), origin = character(0),
    n_distinct_ips = integer(0), n_downloads = integer(0), stringsAsFactors = FALSE)
  r <- oldstats_rollup(empty)
  expect_equal(nrow(r), 0L)
  expect_equal(names(r), c("package", "category", "origin",
    "total_downloads", "months_active", "first_month", "last_month"))
})
