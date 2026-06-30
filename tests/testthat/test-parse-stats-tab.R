test_that("parse_stats_tab reads the aggregate TSV by header, ignoring column order", {
  text <- paste(
    "Package\tYear\tMonth\tNb_of_distinct_IPs\tNb_of_downloads",
    "a4\t2026\tJan\t163\t239",
    "a4\t2026\tall\t163\t239",
    "DESeq2\t2025\tDec\t9000\t25000",
    sep = "\n")
  df <- parse_stats_tab(text, "software")
  expect_equal(nrow(df), 3L)
  expect_equal(df$package, c("a4", "a4", "DESeq2"))
  expect_equal(df$category, rep("software", 3L))
  expect_equal(df$year, c(2026L, 2026L, 2025L))
  expect_equal(df$month_token, c("Jan", "all", "Dec"))
  expect_equal(df$n_distinct_ips, c(163L, 163L, 9000L))
  expect_equal(df$n_downloads, c(239L, 239L, 25000L))
  expect_type(df$year, "integer")
})
