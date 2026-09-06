#!/usr/bin/env Rscript

options(stringsAsFactors = FALSE)
options(timeout = max(3600, getOption("timeout")))

args <- commandArgs(trailingOnly = TRUE)
value_arg <- function(prefix, default = NULL) {
  hit <- args[startsWith(args, paste0(prefix, "="))]
  if (!length(hit)) return(default)
  sub(paste0("^", prefix, "="), "", hit[[length(hit)]])
}

dataset_arg <- value_arg("--dataset", "")
out_root <- path.expand(value_arg("--out", "~/fastPLS_sources"))
dry_run <- "--dry-run" %in% args
list_only <- "--list" %in% args

catalog <- data.frame(
  dataset = c(
    "metref", "cbmc_citeseq", "cifar100", "ccle", "gtex_v8",
    "imagenet", "nmr", "prism", "retina", "tabula", "tcga_brca",
    "tcga_hnsc_methylation", "tcga_pan_cancer"
  ),
  prepared_object = c(
    "metref.RData", "cbmc_citeseq.RData", "CIFAR100.RData",
    "ccle.RData", "gtex_v8.RData", "imagenet.RData", "nmr.RData",
    "prism.RData", "Macosko2015_retina_float32.RData",
    "TabulaMuris_float32.RData", "tcga_brca.RData",
    "tcga_hnsc_methylation.RData", "tcga_pan_cancer.RData"
  ),
  access = c(
    "public-package", "public-GEO", "public-download",
    "historical-release", "public-open-access", "gated-noncommercial",
    "source-study-terms", "release-controlled", "public-GEO",
    "public-Bioconductor", "public-open-access", "public-open-access",
    "public-open-access"
  ),
  redistributed = FALSE,
  stringsAsFactors = FALSE
)

if (list_only) {
  print(catalog, row.names = FALSE)
  quit(status = 0L)
}

if (!nzchar(dataset_arg)) {
  stop(
    "Specify --dataset=<id[,id...]> or --list. See benchmark/DATA_ACQUISITION.md.",
    call. = FALSE
  )
}

requested <- unique(trimws(strsplit(dataset_arg, ",", fixed = TRUE)[[1L]]))
if ("all" %in% requested) requested <- catalog$dataset
unknown <- setdiff(requested, catalog$dataset)
if (length(unknown)) {
  stop("Unknown dataset id(s): ", paste(unknown, collapse = ", "), call. = FALSE)
}

dir.create(out_root, recursive = TRUE, showWarnings = FALSE)
manifest_path <- file.path(out_root, "acquisition_manifest.csv")
rows <- list()

md5_or_na <- function(path) {
  if (!file.exists(path) || dir.exists(path)) return(NA_character_)
  unname(tools::md5sum(path))
}

record <- function(dataset, source, access, local_path = NA_character_,
                   status = "success", message = "") {
  local_path <- as.character(local_path)
  if (!length(local_path)) local_path <- NA_character_
  for (path in local_path) {
    exists <- !is.na(path) && file.exists(path)
    rows[[length(rows) + 1L]] <<- data.frame(
      dataset = dataset,
      source = source,
      access = access,
      redistributed_by_fastPLS = FALSE,
      local_path = if (is.na(path)) NA_character_ else
        normalizePath(path, winslash = "/", mustWork = FALSE),
      bytes = if (exists && !dir.exists(path)) file.info(path)$size else NA_real_,
      md5 = if (exists) md5_or_na(path) else NA_character_,
      status = status,
      message = message,
      timestamp_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
      stringsAsFactors = FALSE
    )
  }
}

download_one <- function(dataset, url, dest) {
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  if (dry_run) {
    record(dataset, url, "public", dest, "dry_run", "Download not executed.")
    return(dest)
  }
  if (!file.exists(dest) || file.info(dest)$size == 0) {
    download.file(url, dest, mode = "wb", quiet = FALSE)
  }
  record(dataset, url, "public", dest)
  dest
}

require_local <- function(dataset, env_vars, source, access) {
  paths <- Sys.getenv(env_vars, unset = "")
  paths <- paths[nzchar(paths)]
  if (!length(paths)) {
    stop(
      "Set one of ", paste(env_vars, collapse = ", "),
      " to an authorized local source or prepared object. See ",
      "benchmark/DATA_ACQUISITION.md."
    )
  }
  missing <- paths[!file.exists(paths)]
  if (length(missing)) stop("Local path does not exist: ", paste(missing, collapse = ", "))
  record(dataset, source, access, paths)
}

download_xena <- function(dataset, ids) {
  if (!requireNamespace("UCSCXenaTools", quietly = TRUE)) {
    stop(
      "Install UCSCXenaTools, then rerun: ",
      "if (!requireNamespace('BiocManager')) install.packages('BiocManager'); ",
      "BiocManager::install('UCSCXenaTools')"
    )
  }
  xena_data <- UCSCXenaTools::XenaData
  query <- UCSCXenaTools::XenaGenerate(
    xena_data[xena_data$XenaDatasets %in% ids, , drop = FALSE]
  )
  query <- UCSCXenaTools::XenaQuery(query)
  if (!nrow(query)) stop("No UCSC Xena records found for: ", paste(ids, collapse = ", "))
  missing_ids <- setdiff(ids, query$datasets)
  if (length(missing_ids)) {
    stop("UCSC Xena release identifier(s) unavailable: ", paste(missing_ids, collapse = ", "))
  }
  out <- file.path(out_root, dataset)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)
  for (i in seq_len(nrow(query))) {
    dest <- file.path(out, basename(query$url[[i]]))
    download_one(dataset, query$url[[i]], dest)
  }
}

acquire <- function(dataset) {
  out <- file.path(out_root, dataset)
  dir.create(out, recursive = TRUE, showWarnings = FALSE)

  if (dataset == "cifar100") {
    return(download_one(
      dataset,
      "https://www.cs.toronto.edu/~kriz/cifar-100-binary.tar.gz",
      file.path(out, "cifar-100-binary.tar.gz")
    ))
  }

  if (dataset == "cbmc_citeseq") {
    base <- "https://ftp.ncbi.nlm.nih.gov/geo/series/GSE100nnn/GSE100866/suppl"
    files <- c(
      "GSE100866_CBMC_8K_13AB_10X-RNA_umi.csv.gz",
      "GSE100866_CBMC_8K_13AB_10X-ADT_umi.csv.gz"
    )
    return(vapply(
      files,
      function(f) download_one(dataset, paste(base, f, sep = "/"), file.path(out, f)),
      character(1)
    ))
  }

  if (dataset == "retina") {
    urls <- c(
      "https://ftp.ncbi.nlm.nih.gov/geo/series/GSE63nnn/GSE63472/suppl/GSE63472_P14Retina_logDGE.txt.gz",
      "http://file.biolab.si/opentsne/benchmark/macosko_2015.pkl.gz"
    )
    return(vapply(
      urls,
      function(url) download_one(dataset, url, file.path(out, basename(url))),
      character(1)
    ))
  }

  if (dataset == "metref") {
    if (!requireNamespace("KODAMA", quietly = TRUE)) {
      stop(
        "Install KODAMA, then rerun: install.packages('KODAMA', ",
        "repos=c('https://tkcaccia.r-universe.dev','https://cloud.r-project.org'))"
      )
    }
    if (dry_run) {
      record(dataset, "KODAMA::MetRef", "public-package",
             file.path(out, "MetRef_source.rds"), "dry_run", "Object not written.")
      return(invisible())
    }
    env <- new.env(parent = emptyenv())
    utils::data("MetRef", package = "KODAMA", envir = env)
    if (!exists("MetRef", envir = env, inherits = FALSE)) {
      stop("KODAMA did not expose the MetRef object.")
    }
    dest <- file.path(out, "MetRef_source.rds")
    saveRDS(get("MetRef", envir = env), dest, compress = "xz")
    record(dataset, "KODAMA::MetRef", "public-package", dest)
    return(dest)
  }

  if (dataset == "tabula") {
    if (!requireNamespace("ExperimentHub", quietly = TRUE)) {
      stop(
        "Install ExperimentHub and TabulaMurisData, then rerun: ",
        "if (!requireNamespace('BiocManager')) install.packages('BiocManager'); ",
        "BiocManager::install(c('ExperimentHub','TabulaMurisData'))"
      )
    }
    if (dry_run) {
      record(dataset, "Bioconductor ExperimentHub EH1617", "public-Bioconductor",
             file.path(out, "EH1617_TabulaMurisDroplet.rds"),
             "dry_run", "ExperimentHub object not resolved.")
      return(invisible())
    }
    hub <- ExperimentHub::ExperimentHub()
    object <- hub[["EH1617"]]
    dest <- file.path(out, "EH1617_TabulaMurisDroplet.rds")
    saveRDS(object, dest, compress = FALSE)
    record(dataset, "Bioconductor ExperimentHub EH1617", "public-Bioconductor", dest)
    return(dest)
  }

  if (dataset == "gtex_v8") {
    return(download_xena(dataset, c("gtex_RSEM_gene_tpm", "GTEX_phenotype")))
  }
  if (dataset == "tcga_brca") {
    return(download_xena(
      dataset,
      c("TCGA.BRCA.sampleMap/HiSeqV2",
        "TCGA.BRCA.sampleMap/BRCA_clinicalMatrix")
    ))
  }
  if (dataset == "tcga_hnsc_methylation") {
    return(download_xena(
      dataset,
      c("TCGA.HNSC.sampleMap/HumanMethylation450",
        "TCGA.HNSC.sampleMap/HNSC_clinicalMatrix")
    ))
  }
  if (dataset == "tcga_pan_cancer") {
    return(download_xena(
      dataset,
      c("EB++AdjustPANCAN_IlluminaHiSeq_RNASeqV2.geneExp.xena",
        "TCGA_phenotype_denseDataOnlyDownload.tsv")
    ))
  }

  if (dataset == "imagenet") {
    return(require_local(
      dataset,
      c("FASTPLS_IMAGENET_RDATA", "FASTPLS_IMAGENET_ROOT"),
      "https://www.image-net.org/download.php",
      "gated-noncommercial"
    ))
  }
  if (dataset == "nmr") {
    return(require_local(
      dataset,
      c("FASTPLS_NMR_RDATA", "FASTPLS_NMR_SOURCE_DIR"),
      paste(
        "https://figshare.com/s/2523b08fe8c2a23a341d;",
        "MetaboLights MTBLS242, MTBLS395, MTBLS424"
      ),
      "source-study-terms"
    ))
  }
  if (dataset == "ccle") {
    prepared <- Sys.getenv("FASTPLS_CCLE_RDATA", unset = "")
    if (nzchar(prepared)) {
      return(require_local(
        dataset,
        "FASTPLS_CCLE_RDATA",
        "DepMap/CCLE 18Q2 historical release",
        "historical-release"
      ))
    }
    expression <- Sys.getenv("FASTPLS_CCLE_EXPRESSION", unset = "")
    annotation <- Sys.getenv("FASTPLS_CCLE_ANNOTATION", unset = "")
    if (!nzchar(expression) || !nzchar(annotation)) {
      stop(
        "Set FASTPLS_CCLE_RDATA, or set both FASTPLS_CCLE_EXPRESSION ",
        "and FASTPLS_CCLE_ANNOTATION to the exact 18Q2 files. See ",
        "benchmark/DATA_ACQUISITION.md."
      )
    }
    missing <- c(expression, annotation)[!file.exists(c(expression, annotation))]
    if (length(missing)) {
      stop("Local path does not exist: ", paste(missing, collapse = ", "))
    }
    record(
      dataset,
      "DepMap/CCLE 18Q2 historical release",
      "historical-release",
      c(expression, annotation)
    )
    return(invisible(c(expression, annotation)))
  }
  if (dataset == "prism") {
    return(require_local(
      dataset,
      c("FASTPLS_PRISM_RDATA", "FASTPLS_PRISM_SOURCE_DIR"),
      "DepMap PRISM Repurposing 19Q4",
      "release-controlled"
    ))
  }

  stop("No acquisition handler for ", dataset)
}

for (dataset in requested) {
  message("[", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "] ", dataset)
  tryCatch(
    acquire(dataset),
    error = function(e) {
      record(
        dataset,
        "See benchmark/DATA_ACQUISITION.md",
        catalog$access[match(dataset, catalog$dataset)],
        NA_character_,
        "failed",
        conditionMessage(e)
      )
      message("  FAILED: ", conditionMessage(e))
    }
  )
}

manifest <- if (length(rows)) do.call(rbind, rows) else data.frame()
utils::write.csv(manifest, manifest_path, row.names = FALSE, na = "")
message("Manifest: ", normalizePath(manifest_path, winslash = "/", mustWork = FALSE))

if (nrow(manifest) && any(manifest$status == "failed")) {
  quit(status = 2L)
}
