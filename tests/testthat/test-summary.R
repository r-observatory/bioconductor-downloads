test_that("summary computes the download score, totals, ranks, and trend", {
  # One package, 12 months of 2025, distinct IPs = 10 each -> score = 120/12 = 10.
  months <- sprintf("2025-%02d-01", 1:12)
  rows <- data.frame(
    package = "limma", category = "software", date = months,
    n_distinct_ips = rep(10L, 12),
    n_downloads = rep(100L, 12), stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))

  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_equal(s$package, "limma")
  expect_equal(s$package_lower, "limma")
  expect_equal(s$category, "software")
  expect_equal(s$download_score, 10.0)
  expect_equal(s$total_last_month, 100L)   # December
  expect_equal(s$total_12mo, 1200L)
  expect_equal(s$rank_score, 1L)
  # last 3 months (Oct+Nov+Dec)=300 vs prior 3 (Jul+Aug+Sep)=300 -> 0% trend
  expect_equal(s$trend, 0.0)
})

test_that("trend is NULL when the prior 3-month window is empty", {
  rows <- data.frame(package = "p", category = "software",
    date = c("2025-11-01", "2025-12-01"),
    n_distinct_ips = c(5L, 5L), n_downloads = c(50L, 50L),
    stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_true(is.na(s$trend))
})

test_that("download_score divides by 12 even when fewer months are present", {
  rows <- data.frame(package = "p", category = "software",
    date = c("2025-11-01", "2025-12-01"),
    n_distinct_ips = c(6L, 6L), n_downloads = c(1L, 1L),
    stringsAsFactors = FALSE)
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))
  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  expect_equal(s$download_score, round((6 + 6) / 12.0, 2))  # = 1.0
})

test_that("rank_score is partitioned by category, not global", {
  # pkgA and pkgB both in "software" with different IPs (scores 10 and 5).
  # pkgC is in "workflows" with IPs lower than both software packages (score 3).
  # pkgC must rank 1 within workflows even though its score is lower than pkgB,
  # proving RANK() OVER (PARTITION BY category ...) rather than a global rank.
  months <- sprintf("2025-%02d-01", 1:12)
  mkrows <- function(pkg, cat, ips) {
    data.frame(package = pkg, category = cat, date = months,
               n_distinct_ips = rep(ips, 12L), n_downloads = rep(1L, 12L),
               stringsAsFactors = FALSE)
  }
  rows <- rbind(mkrows("pkgA", "software",  10L),
                mkrows("pkgB", "software",   5L),
                mkrows("pkgC", "workflows",  3L))
  con <- mk_con(rows); on.exit(DBI::dbDisconnect(con))

  s <- DBI::dbGetQuery(con, summary_sql("2025-12-01"))
  s <- s[order(s$category, s$package), ]

  pkgA <- s[s$package == "pkgA", ]
  pkgB <- s[s$package == "pkgB", ]
  pkgC <- s[s$package == "pkgC", ]

  # scores
  expect_equal(pkgA$download_score, round(10 * 12 / 12.0, 2))  # 10.0
  expect_equal(pkgB$download_score, round( 5 * 12 / 12.0, 2))  #  5.0
  expect_equal(pkgC$download_score, round( 3 * 12 / 12.0, 2))  #  3.0

  # per-category ranks: pkgA beats pkgB in software; pkgC is rank 1 in workflows
  expect_equal(pkgA$rank_score, 1L)
  expect_equal(pkgB$rank_score, 2L)
  expect_equal(pkgC$rank_score, 1L)
})
