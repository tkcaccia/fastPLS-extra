#!/usr/bin/env python3
"""Compress the CMPB main manuscript while preserving its evidence contract."""

from __future__ import annotations

import argparse
from pathlib import Path
import re

from docx import Document


REPLACEMENTS = {
    "Partial least squares (PLS) regression predicts": (
        "Partial least squares (PLS) regression predicts one or more response "
        "variables using components constructed as linear combinations of the "
        "predictors. By combining supervised dimension reduction with prediction, "
        "PLS is well suited to omics data in which variables are correlated or "
        "outnumber observations [1,2]. PLS discriminant analysis is widely used "
        "in metabolomics, including studies of inflammatory prostate cancer [3] "
        "and altered cholesterol metabolism in pancreatic cancer, gallbladder "
        "cancer and acute pancreatitis [4-6]."
    ),
    "As biological applications have grown": (
        "The computational burden increases with sample size, spectral "
        "resolution, response dimension and repeated validation. Recent NMR work "
        "used PLS to reconstruct complementary one-dimensional spectra from one "
        "NOESY acquisition, with final models containing up to 250 components "
        "[7]. Similar pressure arises when PLS-DA is fitted repeatedly inside "
        "iterative workflows such as KODAMA rather than fitted once."
    ),
    "Several algorithmic formulations of PLS have been proposed": (
        "PLS implementations include NIPALS-type sequential deflation [8], linear "
        "and wide kernel algorithms [9], improved kernel PLS (IKPLS) [10], "
        "nonlinear kernel PLS [11], and SIMPLS [12]. IKPLS reduces redundant "
        "arithmetic by reformulating sequential updates so that only one predictor "
        "or response matrix is deflated. SIMPLS instead obtains latent factors "
        "directly from the original variables without constructing deflated data "
        "matrices. Their computational and storage costs depend on the relative "
        "numbers of observations, predictors and responses."
    ),
    "Singular value decomposition (SVD)-based formulations": (
        "SVD-based PLS provides another route [13]. Truncated Lanczos and "
        "randomized decompositions can reduce work when only a limited set of "
        "singular directions is required [14,15]. OPLS further separates "
        "predictive variation from structured predictor variation unrelated to "
        "the response [16]."
    ),
    "Here we present fastPLS": (
        "We present fastPLS implementations of PLS-SVD, a SIMPLS-family "
        "estimator, OPLS and kernel PLS. Reusable matrix products, compact "
        "prediction factors and specialized multivariate and multiclass "
        "operations reduce repeated computation. We evaluate numerical "
        "agreement, CPU and CUDA performance, cross-validation, NMR spectral "
        "reconstruction and million-sample foundation-model embeddings."
    ),
    "Let X contain n observations": (
        "Let X contain n observations and p centred predictors, and let Y contain "
        "q centred responses. Their cross-covariance is S = X\u1d40Y. fastPLS can "
        "store this p by q matrix or apply it implicitly, for example as "
        "S\u03a9 = X\u1d40(Y\u03a9), without materializing S. This reduces storage "
        "when both p and q are large, at the cost of additional passes through "
        "the data."
    ),
    "Classical SIMPLS extracts successive directions": (
        "Classical SIMPLS extracts successive directions while orthogonalizing "
        "predictor loadings and deflating the cross-covariance [12]. The public "
        "simpls method retains these sequential updates, reuses each deflation "
        "product and stores only factors needed for prediction (Algorithm 1). "
        "Sample-space response products avoid repeatedly multiplying large "
        "multivariate responses, while class sums avoid dense indicator matrices. "
        "Some large problems obtain a bounded candidate block from one deflated "
        "state and then apply sequential orthogonalization and deflation to each "
        "accepted candidate. Because the leading direction is not recomputed "
        "after every component in that block, this is a SIMPLS-family rather than "
        "classical de Jong SIMPLS estimator."
    ),
    "PLS-SVD approximates S": (
        "PLS-SVD approximates S as UD V\u1d40 and projects X through retained "
        "columns of U. Regression in this space uses the score Gram matrix, which "
        "may be formed as (XU)\u1d40(XU) or U\u1d40(X\u1d40X)U when a predictor Gram "
        "matrix is reusable. Leading prefixes support several component counts "
        "from one decomposition (Algorithm 2), while the numerical rank of S "
        "limits the available components."
    ),
    "OPLS first filters": (
        "OPLS filters response-orthogonal predictor variation before fitting the "
        "predictive PLS model (Algorithm S1). Linear kernel PLS uses predictor "
        "products directly, whereas nonlinear kernel PLS constructs and centres "
        "an n by n kernel matrix (Algorithm S2); its quadratic storage limits "
        "practical sample size."
    ),
    "Ten exact algebraic identities": (
        "Ten exact algebraic identities used by the optimized PLS-SVD, "
        "SIMPLS-family, OPLS, kernel PLS and cross-validation paths were formalized "
        "in Lean 4 with Mathlib [17,18]. They cover implicit products, compact "
        "prediction, deflation, kernel centring and fold-statistic subtraction. "
        "The project pins the Lean toolchain and Mathlib revision; sources are "
        "provided under Phase1/formal/lean in fastPLS-extra."
    ),
    "Classification was evaluated using either": (
        "Classification used either argmax of reconstructed class responses or "
        "linear discriminant analysis (LDA) fitted to PLS scores for G classes. "
        "LDA used pooled within-class covariance with an automatically increased "
        "ridge term when Cholesky factorization failed. Regression returned "
        "continuous predictions."
    ),
    "Single and nested cross-validation were implemented": (
        "Single and nested cross-validation optionally kept all observations "
        "from the same donor or patient in one fold, in both outer and inner "
        "partitions."
    ),
    "For eligible compiled routes": (
        "Eligible compiled routes calculated additive sufficient statistics once "
        "and obtained each training-fold statistic by subtracting the held-out "
        "contribution before centring, scaling, PLS or LDA fitting. Thus, no "
        "held-out-derived parameter entered training. Nonlinear kernel matrices "
        "remained fold specific. If a fold yielded fewer directions than "
        "requested, higher prefixes repeated the last estimable prediction; a "
        "zero-direction regression predicted the training mean, and degenerate "
        "classification used the training-fold prior or sole observed class. "
        "Diagnostics retained these events and effective component counts. "
        "Selection metrics included accuracy, balanced accuracy, RMSD and Q\u00b2Y "
        "(Algorithm 3)."
    ),
    "The timing comparison used one fixed": (
        "The timing experiment compared complete 10-fold validation with one "
        "full-training fit and fixed-test prediction, using the same previously "
        "selected component count, PLS family and LDA or regression output. Fold "
        "construction, fitting, prediction and out-of-fold assembly were timed; "
        "loading and initial conversion were excluded. CUDA timings included "
        "initialization, transfers and synchronization."
    ),
    "The study comprised nine classification datasets": (
        "The benchmark comprised nine classification tasks, three regression "
        "tasks and an ImageNet embedding experiment (Table 1). MetRef came from "
        "KODAMA-associated NMR resources [19-21]; GTEx, TCGA, CCLE, CITE-seq, "
        "retina, Tabula Muris and PRISM data were obtained from their recorded "
        "public releases [22-30]. CIFAR-100 [31] and ImageNet/DINOv2 [32,33] were "
        "represented by fixed embeddings. The NMR task retained the supplied 1,200/321 "
        "training/test split and predicted 28,355 diffusion-edited intensities "
        "from 13,000 NOESY bins [7]. Detailed acquisition, filtering and "
        "preprocessing are provided in the Supplementary material. All methods "
        "used identical fixed partitions; these computational splits are not "
        "independent-patient validation."
    ),
    "MetRef. The urine": "",
    "GTEx v8. Gene-level": "",
    "TCGA Pan-Cancer. TCGA": "",
    "CCLE. The benchmark": "",
    "TCGA-BRCA. RNA-seq": "",
    "TCGA-HNSC methylation": "",
    "CBMC CITE-seq. RNA": "",
    "Retina. The retina": "",
    "Tabula Muris. The Tabula": "",
    "PRISM. Cancer cell": "",
    "NMR regression. The source": "",
    "CIFAR-100. The official": "",
    "ImageNet/DINOv2. Authorized": "",
    "fastPLS was benchmarked on every prepared task": (
        "All programs used the same partitions, dataset-specific component counts "
        "and one effective CPU thread on an Intel Core i7-13700 workstation with "
        "32 GiB RAM. The main comparison used LDA for classification and continuous "
        "regression, float32 when supported, and omitted unneeded fitted responses, "
        "loadings and variance summaries. Ordinary fastPLS, IKPLS and scikit-learn "
        "rows used ten fresh processes. Independent R packages used up to three "
        "1,800-s attempts, stopping after the first timeout or resource failure; "
        "fastPLS ImageNet and Python NMR/ImageNet used one run. Unsupported routes, "
        "failures and timeouts were retained rather than extrapolated."
    ),
    "The CPU and CUDA experiments": (
        "CPU/CUDA experiments used the same Linux workstation with an RTX 5060 Ti "
        "16-GiB GPU and one OpenBLAS thread. Cold timings included first-use "
        "library and accelerator initialization; warm timings repeated the "
        "operation after initialization. Timings included fitting, prediction, "
        "transfers and synchronization but excluded loading and conversion. Peak "
        "RSS measured the complete process, including runtimes, prepared data, "
        "models, predictions and temporary allocations. External comparisons use "
        "absolute RSS; backend comparisons use the increment above baseline and "
        "report CUDA allocation separately."
    ),
    "Classification differences were expressed": (
        "Component counts were selected within explicit training-only grids; "
        "grids, rules, eligible NMR values and retained counts are reported in the "
        "Supplement. Classification differences use percentage points and "
        "regression differences use relative RMSD. Independent implementations "
        "retain their native estimators, precision and model objects, and no "
        "selected count is described as a global optimum."
    ),
    "The 5-ms sampler was identical": (
        "The same 5-ms process sampler was used for R workflows; GNU time supplied "
        "an operating-system maximum-RSS check for Python workflows."
    ),
    "Numerical validation preceded interpretation": (
        "Before performance analysis, 82 SIMPLS-family component-prefix checks, "
        "348 CPU/CUDA rSVD checks, 18 OPLS or nonlinear-kernel cases and 22 "
        "float32/float64 pairs met their stated criteria (Supplementary Table S1)."
    ),
    "The Lean proof checker also accepted": (
        "Lean accepted all ten exact-real identities in Supplementary Table S2. "
        "These proofs validate algebraic transformations, not floating-point "
        "kernels, randomized convergence or the complete C++ program."
    ),
    "We evaluated fastPLS across": (
        "Thirteen tasks were evaluated: nine classification datasets, CBMC "
        "CITE-seq, PRISM and NMR regression, and the ImageNet experiment (Table 1). "
        "Supplementary Tables S3-S4 give independent-software settings and the "
        "timing/memory contract; Supplementary Figures S1-S12 show component paths."
    ),
    "The exact independent-software calls": "",
    "The benchmark summary included 13": "",
    "fastPLS had the lowest median fitting-and-prediction time": (
        "fastPLS had the lowest or tied-lowest median time among completed R "
        "workflows on all nine classification datasets and completed every "
        "regression task (Figure 1). Other R workflows timed out or exhausted "
        "memory on ImageNet, NMR or both."
    ),
    "The classification results also show": (
        "On Tabula Muris, fastPLS with LDA attained 86.90% accuracy and 80.47% "
        "balanced accuracy, versus 79.34% and 59.02% for IKPLS with argmax. "
        "Although estimator and output differences prevent attributing the gains "
        "solely to LDA, the latent-space classifier materially changed prediction."
    ),
    "IKPLS and fastPLS had comparable": (
        "Runtimes were similar on many smaller tasks. On ImageNet, fastPLS "
        "completed 1,000 components in 63.933 s versus 180.091 s for IKPLS "
        "(2.82-fold), with top-1 accuracy 0.8094 versus 0.7999. This is an "
        "end-to-end comparison of different estimators and prediction heads."
    ),
    "The multivariate NMR problem exposed": (
        "For NMR, fastPLS predicted 28,355 responses from 13,000 bins in 4.585 s; "
        "IKPLS exceeded available memory, while scikit-learn completed NMR but "
        "not ImageNet. fastPLS was the only compared implementation to complete "
        "both workloads. Its largest Figure 1 process peak was 9,822 MiB on "
        "ImageNet."
    ),
    "Figure 1. Prediction, runtime and memory": (
        "Figure 1. Held-out prediction, fitting-plus-prediction time and absolute "
        "peak RSS on one Intel Core i7-13700 thread. fastPLS uses SIMPLS-family "
        "LDA for classification and continuous regression. Cells are medians of "
        "successful runs; replication and failures are reported in Methods and "
        "Supplementary Table S4."
    ),
    "CUDA was evaluated in all 52": (
        "CUDA reduced fitting-plus-prediction time in 14 of 52 paired routes "
        "(Figure 2A). CPU/CUDA ratios ranged from 0.93-1.72 on CIFAR-100, "
        "40.18-193.46 on ImageNet, 3.43-17.23 on NMR and 0.59-3.83 on PRISM; "
        "values below one favoured CPU."
    ),
    "Across the 11 datasets completed": (
        "Across 11 tasks completed by both CUDA implementations, median "
        "IKPLS/fastPLS runtime ratios were 8.47 at first use and 19.46 after "
        "initialization; IKPLS used 2.39-fold more median host memory "
        "(Supplementary Figure S13)."
    ),
    "Predictive performance was similar for regression": (
        "Regression RMSD differed by 0.41% on CBMC CITE-seq and 0.12% on PRISM. "
        "CUDA IKPLS failed on NMR after requesting about 68.7 GiB for its "
        "coefficient path and encountered a device-allocation failure on ImageNet."
    ),
    "Complete 10-fold cross-validation with LDA": (
        "Complete 10-fold validation cost a median 4.08 times one matched fit and "
        "prediction on CPU (range 0.58-9.62) and 2.14 times on CUDA "
        "(1.06-8.49); no ratio exceeded ten (Figure 2C,D). CUDA OPLS ratios were "
        "3.26 for PRISM, 4.35 for NMR and 8.49 for ImageNet. Component counts "
        "were fixed, but LDA was refitted in every training fold."
    ),
    "CUDA increased the baseline-corrected": (
        "CUDA increased host-RSS increments in 48 of 52 routes (median ratio "
        "5.21), largely because of libraries, allocator pools and staging "
        "buffers; large tasks also moved storage to the device "
        "(Supplementary Tables S5-S6)."
    ),
    "Figure 2. CPU and CUDA performance": (
        "Figure 2. CPU/CUDA comparisons on the Intel Core i7-13700/RTX 5060 Ti "
        "workstation with float32 inputs. A: CPU/CUDA fitting-plus-prediction "
        "time ratio. B: CUDA/CPU host-RSS increment ratio. A-B use argmax. C-D: "
        "10-fold validation divided by one matched fit and prediction on CPU and "
        "CUDA; classification uses fold-refitted LDA. For C-D, five fresh "
        "processes were used except one for ImageNet. Timings include accelerator "
        "initialization, transfer and synchronization; TO denotes 1,800 s."
    ),
    "The NMR application addresses": (
        "The NMR task reconstructs complementary spectra from one NOESY "
        "acquisition [7]. Five paired training-only splits and the "
        "one-standard-error rule selected 75 PLS-SVD and 50 SIMPLS-family "
        "components within the evaluated grid (Supplementary Figure S12)."
    ),
    "The accelerated implementations improved": (
        "At the predefined reporting points, CUDA PLS-SVD required 0.492 s for "
        "100 components and CUDA SIMPLS-family 0.468 s for 50, versus 438.862 s "
        "for the deposited 165-component workflow: 892- and 938-fold differences. "
        "Test RMSD was 0.0007194, 0.0007230 and 0.0007858, respectively "
        "(Figure 3)."
    ),
    "Memory use also decreased": (
        "Host-RSS increments were 3,872 MiB for the deposited workflow, 590 MiB "
        "for CUDA PLS-SVD and 568 MiB for CUDA SIMPLS-family; CUDA device peaks "
        "were 564 and 440 MiB. These workflow-level comparisons differ in family, "
        "solver, precision and component count."
    ),
    "The per-spectrum errors show": (
        "Figure 3D-F shows per-spectrum error and a spectrum nearest the median "
        "CPU SIMPLS-family error. Response-wise and intensity-stratified errors "
        "are reported in Supplementary Figure S14."
    ),
    "Figure 3. NMR spectral prediction": (
        "Figure 3. NMR prediction using float32 fastPLS at 100 PLS-SVD and 50 "
        "SIMPLS-family components, versus the deposited float64 165-component "
        "workflow. A: median time and interquartile range from three processes. "
        "B: test RMSD over 28,355 responses. C: host-RSS increment and CUDA "
        "allocation. D: per-spectrum RMSD. E-F: observed and predicted spectra "
        "nearest the median CPU SIMPLS-family error. Selection and complete paths "
        "are in Supplementary Figure S12."
    ),
    "Foundation models produce dense reusable embeddings": (
        "PLS can adapt correlated foundation-model embeddings to supervised "
        "endpoints. On ImageNet/DINOv2, 50-component argmax attained 49.30% "
        "top-1 and 76.41% top-5 accuracy, while LDA attained 75.91% and 91.50%. "
        "At 1,000 components, values were 79.99%/95.61% for argmax and "
        "80.94%/93.93% for LDA (Figure 4). Nonlinear kernel PLS was infeasible: "
        "the one-trillion-entry Gram matrix alone requires about 3.6 TiB in "
        "float32. This nonstandard, incompletely documented split supports "
        "computational feasibility, not clinical performance."
    ),
    "The complete SIMPLS-family ImageNet": (
        "Supplementary Table S7 gives the complete ImageNet path; Supplementary "
        "Table S8 records the Linux, OpenBLAS and CUDA platform."
    ),
    "Figure 4. ImageNet/DINOv2 classification": (
        "Figure 4. ImageNet/DINOv2 SIMPLS-family classification with float32 "
        "CUDA. A: held-out top-1/top-5 accuracy for argmax and LDA prefixes. "
        "B: fitting and top-5 prediction time. C: host RSS and CUDA allocation. "
        "Prefixes reuse one 1,000-component fit with rSVD oversampling 32, five "
        "power iterations and seed 123. This is one exploratory run; 1,000 is "
        "the tested boundary, not an optimum."
    ),
    "The results show that fastPLS gains": (
        "fastPLS gained most when compact factors and selective output "
        "construction avoided dense paths. It was 2.82-fold faster than IKPLS "
        "on ImageNet and the only compared implementation to complete both "
        "ImageNet and NMR; smaller tasks were often separated by milliseconds."
    ),
    "Prediction accuracy depended not only": (
        "Prediction depended not only on the PLS representation but also on its "
        "classification head. PLS-LDA models class structure in latent score "
        "space, whereas argmax selects the largest reconstructed indicator "
        "response. This distinction was clearest in Tabula Muris and the ImageNet "
        "component paths: LDA separated classes effectively with a short score "
        "representation, while argmax benefited more from additional components "
        "and gave the higher ImageNet top-5 accuracy at the upper boundary. "
        "Because programs also differ in estimator and outputs, the contrast does "
        "not isolate LDA, but it establishes the prediction head and selection "
        "metric as substantive modelling choices."
    ),
    "The numerical results also clarify": (
        "rSVD remains approximate and depends on the spectrum, seed and controls. "
        "Bounded candidate blocks also distinguish the implemented SIMPLS-family "
        "route from classical SIMPLS. Dense-reference, multi-seed, precision and "
        "backend checks met the stated criteria but do not establish universal "
        "numerical equivalence."
    ),
    "Formal verification complements": (
        "Lean verified the exact-real identities used by the optimized paths, "
        "but not floating-point kernels, randomized approximation or end-to-end "
        "C++ execution; numerical and platform tests remain necessary."
    ),
    "CUDA was beneficial only after": (
        "CUDA helped only when work offset initialization and transfer. It sped "
        "14 of 52 fits but increased host-RSS increments in 48. Compiled "
        "cross-validation limited median cost to 4.08 fits on CPU and 2.14 on "
        "CUDA by reusing additive statistics and component prefixes, which is "
        "valuable for repeated-validation tools such as KODAMA [19,20]."
    ),
    "The NMR experiment provides": (
        "NMR provided the strongest biomedical demonstration: training-only "
        "selection retained 75 PLS-SVD and 50 SIMPLS-family components, and the "
        "CUDA workflows were 892- and 938-fold faster than the deposited workflow "
        "with lower global RMSD and host memory. Because family, solver, precision "
        "and component count differ, this is a workflow-level comparison; "
        "localized errors still require scientific interpretation."
    ),
    "The ImageNet experiment addresses": (
        "ImageNet addresses whether supervised PLS can operate on the large "
        "embedding matrices produced by foundation models. The tested PLS "
        "families completed the million-sample CUDA analysis, whereas nonlinear "
        "kernel PLS was impractical because of quadratic Gram storage. ImageNet "
        "is not biomedical, the split is nonstandard and incomplete extraction "
        "metadata limit exact reconstruction; the result is computational "
        "feasibility, not clinical validation. It nevertheless motivates "
        "patient-separated studies of pathology representations from UNI, "
        "UNI2-h and Prov-GigaPath [34,35,36]. Fixed splits, process-level memory and "
        "different returned objects also limit causal attribution of software "
        "differences."
    ),
    "The CUDA software comparison also separates": (
        "The CUDA software comparison separates cold from warm timing. Cold "
        "execution includes process, framework and CUDA-context initialization; "
        "warm execution begins after those resources exist. The larger warm "
        "advantage indicates that compact factors, persistent workspaces and "
        "reduced framework overhead contribute alongside GPU matrix multiplication."
    ),
    "Device-memory consumption was not uniformly": (
        "Device-memory consumption was not uniformly lower for fastPLS. Persistent "
        "CUDA workspaces raised peaks on several small classification tasks, while "
        "fastPLS used less device memory on CIFAR-100, CBMC CITE-seq and PRISM. "
        "The principal advantage was lower host-process memory and completion of "
        "the largest workloads, not universally lower GPU allocation."
    ),
    "This comparison should be described": (
        "The independent benchmark is end to end rather than estimator matched. "
        "IKPLS implements improved kernel PLS with argmax classification, whereas "
        "fastPLS combines a SIMPLS-family representation with pooled-covariance "
        "LDA. Timing and feasibility are therefore directly comparable under the "
        "common input and component contract, but classification differences "
        "cannot be attributed solely to the latent-variable algorithm."
    ),
    "Reusable matrix calculations and compact model factors": (
        "Reusable matrix products and compact factors make large sequential PLS "
        "and repeated validation practical. CPU or CUDA choice remains "
        "workload dependent, and approximate routes require numerical checks. "
        "The shared core is available through R, Python and MATLAB interfaces."
    ),
}


def normalize(text: str) -> str:
    return " ".join(text.split())


def remove_paragraph(paragraph) -> None:
    element = paragraph._element
    element.getparent().remove(element)
    paragraph._p = paragraph._element = None


def replace_by_prefix(document, prefix: str, replacement: str) -> None:
    matches = [p for p in document.paragraphs if normalize(p.text).startswith(prefix)]
    if len(matches) != 1:
        raise RuntimeError(f"Expected one paragraph starting {prefix!r}; found {len(matches)}")
    paragraph = matches[0]
    if replacement:
        paragraph.text = replacement
    else:
        remove_paragraph(paragraph)


def fix_abstract(document) -> None:
    for paragraph in document.paragraphs:
        if normalize(paragraph.text).startswith("Results: fastPLS had the lowest"):
            paragraph.text = paragraph.text.replace(
                "and was the only compared implementation to complete the "
                "matched large multivariate task.",
                "and, together with ImageNet, made fastPLS the only compared "
                "implementation to complete both largest workloads.",
            )
            return
    raise RuntimeError("Structured abstract Results paragraph was not found")


def count_words(document) -> tuple[int, int]:
    in_body = False
    body = []
    captions = []
    for paragraph in document.paragraphs:
        text = normalize(paragraph.text)
        if text == "1. Introduction":
            in_body = True
        if text == "Declarations":
            break
        if not in_body or not text:
            continue
        words = re.findall(r"\b[\w'-]+\b", text)
        body.extend(words)
        if text.startswith(("Figure ", "Table ", "Algorithm ")):
            captions.extend(words)
    return len(body), len(body) - len(captions)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    document = Document(args.input)
    fix_abstract(document)
    for prefix, replacement in REPLACEMENTS.items():
        replace_by_prefix(document, prefix, replacement)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    document.save(args.output)
    including_captions, excluding_captions = count_words(document)
    print(args.output)
    print(f"Introduction-through-Conclusions words including captions: {including_captions}")
    print(f"Introduction-through-Conclusions words excluding captions: {excluding_captions}")


if __name__ == "__main__":
    main()
