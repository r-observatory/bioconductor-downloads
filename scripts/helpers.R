# scripts/helpers.R: pure functions used by update.R, unit-tested in tests/testthat/.

`%||%` <- function(a, b) if (is.null(a)) b else a

# The four Bioconductor stat categories. The (dir, prefix) pair is hardcoded
# because the file prefix is not derivable from the dir: data-annotation uses the
# "annotation_" prefix and data-experiment uses "experiment_".
category_tuples <- function() {
  list(
    list(dir = "bioc",            prefix = "bioc_",       label = "software"),
    list(dir = "data-annotation", prefix = "annotation_", label = "data-annotation"),
    list(dir = "data-experiment", prefix = "experiment_", label = "data-experiment"),
    list(dir = "workflows",       prefix = "workflows_",  label = "workflows")
  )
}

# Aggregate "all packages, all months" file path for a category tuple.
category_file <- function(ct) sprintf("%s/%spkg_stats.tab", ct$dir, ct$prefix)

# Parse the 5-column aggregate stats TSV text into a tidy long data frame. Columns
# are addressed by header name (Package, Year, Month, Nb_of_distinct_IPs,
# Nb_of_downloads) so a future column reorder upstream cannot silently misalign.
parse_stats_tab <- function(text, category) {
  con <- textConnection(text)
  on.exit(close(con))
  df <- utils::read.delim(con, sep = "\t", header = TRUE,
                          colClasses = "character", check.names = FALSE,
                          quote = "", na.strings = character(0))
  data.frame(
    package        = df$Package,
    category       = category,
    year           = as.integer(df$Year),
    month_token    = df$Month,
    n_distinct_ips = as.integer(df$Nb_of_distinct_IPs),
    n_downloads    = as.integer(df$Nb_of_downloads),
    stringsAsFactors = FALSE)
}
