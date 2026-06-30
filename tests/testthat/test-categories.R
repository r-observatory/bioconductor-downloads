test_that("category_tuples covers the four categories with the filename quirk", {
  cts <- category_tuples()
  expect_equal(length(cts), 4L)
  labels <- vapply(cts, function(x) x$label, character(1))
  expect_setequal(labels,
    c("software", "data-annotation", "data-experiment", "workflows"))

  by_label <- function(l) Filter(function(x) x$label == l, cts)[[1]]
  expect_equal(category_file(by_label("software")), "bioc/bioc_pkg_stats.tab")
  expect_equal(category_file(by_label("data-annotation")),
               "data-annotation/annotation_pkg_stats.tab")
  expect_equal(category_file(by_label("data-experiment")),
               "data-experiment/experiment_pkg_stats.tab")
  expect_equal(category_file(by_label("workflows")),
               "workflows/workflows_pkg_stats.tab")
})
