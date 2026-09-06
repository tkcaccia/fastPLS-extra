args <- commandArgs(TRUE)
stopifnot(length(args) == 2L, !grepl("frozen", args[[1L]], ignore.case = TRUE))
.libPaths(c(args[[1L]], .libPaths()))
library(fastPLS)
stopifnot(capabilities("profmem"))
out <- args[[2L]]
dir.create(out, recursive = TRUE, showWarnings = FALSE)
n <- 8000L
p <- 512L
X <- float::fl(matrix(sin(seq_len(n * p) / 100), n, p))
center <- float::fl(seq_len(p) / p)
scale <- float::fl(1 + seq_len(p) / p)
ns <- asNamespace("fastPLS")
standardize <- if (exists(".float32_standardize", ns, inherits = FALSE)) {
    get(".float32_standardize", ns)
} else {
    function(X, center, scale) fastPLS:::.float32_sweep_cols(
        fastPLS:::.float32_sweep_cols(X, center, "-"), scale, "/")
}
operations <- list(
    standardize = function() standardize(X, center, scale),
    zeros = function() fastPLS:::.float32_zeros(n, p)
)
rows <- list()
for (name in names(operations)) {
    fun <- operations[[name]]
    invisible(fun())
    elapsed <- replicate(20L, {
        gc(FALSE)
        unname(system.time(invisible(fun()))[["elapsed"]])
    })
    profile <- file.path(out, paste0(name, "_allocations.txt"))
    gc(FALSE)
    # Profiling is separate from timing. These are R-managed allocations,
    # not complete-process peak RSS or untracked library/device allocations.
    Rprofmem(profile, threshold = 0)
    value <- fun()
    Rprofmem(NULL)
    allocations <- suppressWarnings(as.numeric(sub(" .*", "", readLines(profile))))
    allocations <- allocations[is.finite(allocations)]
    tmp <- tempfile()
    writeBin(as.vector(value@Data), tmp)
    checksum <- unname(tools::md5sum(tmp))
    unlink(tmp)
    rows[[name]] <- data.frame(
        operation = name, n, p, precision = "float32", repetitions = length(elapsed),
        median_sec = median(elapsed), iqr_sec = IQR(elapsed),
        r_allocated_mib = sum(allocations) / 1024^2,
        largest_r_allocation_mib = max(allocations) / 1024^2,
        input_payload_mib = n * p * 4 / 1024^2,
        output_bits_md5 = checksum, stringsAsFactors = FALSE)
    write.csv(data.frame(replicate = seq_along(elapsed), elapsed_sec = elapsed),
        file.path(out, paste0(name, "_timing.csv")), row.names = FALSE)
    write.csv(do.call(rbind, rows), file.path(out, "summary.csv"), row.names = FALSE)
    rm(value)
}
print(do.call(rbind, rows))
