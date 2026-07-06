test_that("classify_origin tags bioc when in the roster, cran otherwise", {
  roster <- c("limma", "DESeq2", "org.Hs.eg.db")
  out <- classify_origin(c("limma", "reticulate", "org.Hs.eg.db", "Limma"), roster)
  expect_equal(out, c("bioc", "cran", "bioc", "cran"))  # case-sensitive: "Limma" != "limma"
})

test_that("classify_origin resolves a CRAN/Bioc name collision to bioc", {
  # A name present in the roster is bioc even if it is also a known CRAN package.
  expect_equal(classify_origin("XML", c("XML", "limma")), "bioc")
})
