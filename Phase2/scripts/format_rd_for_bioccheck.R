#!/usr/bin/env Rscript

files <- list.files("man", pattern = "[.]Rd$", full.names = TRUE)

wrap_line <- function(line, width = 80L) {
    indent <- sub("^([[:space:]]*).*", "\\1", line)
    output <- character()
    remaining <- line
    while (nchar(remaining, type = "width") > width) {
        chars <- strsplit(remaining, "", fixed = TRUE)[[1L]]
        candidates <- which(chars == " " & seq_along(chars) <= width)
        candidates <- candidates[candidates > nchar(indent) + 8L]
        if (!length(candidates)) {
            break
        }
        split_at <- max(candidates)
        output <- c(output, sub("[[:space:]]+$", "", substr(
            remaining, 1L, split_at - 1L
        )))
        remaining <- paste0(
            indent,
            sub("^[[:space:]]+", "", substr(
                remaining, split_at + 1L, nchar(remaining)
            ))
        )
    }
    c(output, remaining)
}

for (path in files) {
    lines <- readLines(path, warn = FALSE)
    in_usage <- FALSE
    in_examples <- FALSE
    output <- character()

    for (line in lines) {
        if (identical(line, "\\usage{")) {
            in_usage <- TRUE
        } else if (identical(line, "\\examples{")) {
            in_examples <- TRUE
        }

        if (in_usage && grepl("^  \\S", line)) {
            line <- sub("^  ", "    ", line)
        }
        if (!in_examples && nchar(line, type = "width") > 80L) {
            output <- c(output, wrap_line(line))
        } else {
            output <- c(output, line)
        }

        if ((in_usage || in_examples) && identical(line, "}")) {
            in_usage <- FALSE
            in_examples <- FALSE
        }
    }

    writeLines(output, path, useBytes = TRUE)
    tools::parse_Rd(path)
}

message("Formatted and parsed ", length(files), " Rd files")
