#!/usr/bin/env python3
"""Restore biomedical PLS application citations in the manuscript."""

import argparse
from pathlib import Path

from docx import Document
from docx.oxml import OxmlElement
from docx.text.paragraph import Paragraph


INTRODUCTION = (
    "Partial least squares (PLS) combines supervised dimension reduction with "
    "prediction and is widely used when biomedical predictors are correlated, "
    "high dimensional or accompanied by multivariate responses [1-3]. "
    "Applications include cancer metabolomics and prediction of multiple "
    "nuclear magnetic resonance (NMR) spectra from one acquisition [4-7]. PLS "
    "can also serve as supervised feature extraction: the latent scores retain "
    "response-relevant structure before a downstream classifier or retrieval "
    "method is applied."
)


REPLACEMENTS = {
    "Several PLS formulations address": (
        "Several PLS formulations address different computational and "
        "statistical settings. PLS-SVD derives directions from a singular "
        "value decomposition of the predictor-response cross-covariance, "
        "whereas SIMPLS extracts sequential components while preserving a "
        "deflation geometry in the original variable space [8]. Orthogonal "
        "PLS separates response-orthogonal variation [9], and kernel PLS "
        "permits nonlinear relations through a kernel representation [10]. "
        "The R package pls provides established implementations [11], while "
        "IKPLS supplies NumPy- and JAX-based improved-kernel PLS algorithms "
        "for CPU and GPU computation [12]. Python alternatives include the "
        "widely used scikit-learn PLSRegression estimator [13] and the "
        "compiled multi-solver nirs4all-methods engine [14]."
    ),
    "For large matrices, the dominant directions": (
        "For large matrices, the dominant directions can be approximated "
        "without a complete singular value decomposition. Randomized SVD "
        "(rSVD) constructs a low-dimensional range approximation and can "
        "replace expensive dense decompositions when the leading subspace is "
        "sufficiently separated [15]. Its approximation depends on rank, "
        "oversampling, power iterations, conditioning and seed; therefore, "
        "computational gains must be interpreted together with numerical "
        "diagnostics."
    ),
    "Multivariate spectral prediction provides": (
        "Multivariate spectral prediction provides a demanding biomedical "
        "example. The deposited workflow associated with a recent NMR study "
        "predicted 28,355 diffusion-edited spectral intensities from 13,000 "
        "NOESY bins in 1,200 training spectra [7]. That implementation used "
        "PLS-SVD with an iterative Lanczos bidiagonalization solver and 165 "
        "components on its original workstation. The response dimension "
        "makes both fitting and prediction expensive, motivating a sequential "
        "SIMPLS implementation that approaches one-shot PLS-SVD execution "
        "while retaining the ability to construct many components."
    ),
    "Large embedding matrices create": (
        "Large embedding matrices create a related computational regime after "
        "feature extraction. Foundation models such as UNI and Prov-GigaPath "
        "produce dense representations for downstream computational pathology "
        "analyses [16,17]. We therefore include DINOv2 embeddings [18] derived "
        "from ImageNet [19] as an engineering stress test of million-sample "
        "matrix processing, not as evidence of biomedical predictive validity."
    ),
    "SIMPLS follows de Jong's": None,
    "OPLS applies response-orthogonal": None,
    "CPU routes are compiled C++": None,
    "The classification comparison used": None,
}


REFERENCES = [
    "[1] Wold S, Sjöström M, Eriksson L. PLS-regression: a basic tool of "
    "chemometrics. Chemometrics and Intelligent Laboratory Systems. "
    "2001;58:109-130. doi:10.1016/S0169-7439(01)00155-1.",
    "[2] Geladi P, Kowalski BR. Partial least-squares regression: a tutorial. "
    "Analytica Chimica Acta. 1986;185:1-17. "
    "doi:10.1016/0003-2670(86)80028-9.",
    "[3] Barker M, Rayens W. Partial least squares for discrimination. Journal "
    "of Chemometrics. 2003;17:166-173. doi:10.1002/cem.785.",
    "[4] Bertini I, Cacciatore S, Jensen BV, et al. Metabolomic NMR "
    "fingerprinting to identify and predict survival of patients with "
    "metastatic colorectal cancer. Cancer Research. 2012;72:356-364. "
    "doi:10.1158/0008-5472.CAN-11-1543.",
    "[5] Cacciatore S, Wium M, Licari C, et al. Inflammatory metabolic profile "
    "of South African patients with prostate cancer. Cancer & Metabolism. "
    "2021;9:29. doi:10.1186/s40170-021-00265-6.",
    "[6] Elebo N, et al. Serum metabolomic and lipoprotein profiling of "
    "pancreatic ductal adenocarcinoma patients of African ancestry. "
    "Metabolites. 2021;11:663. doi:10.3390/metabo11100663.",
    "[7] Vignoli A, Cacciatore S, Tenori L. Deriving three one-dimensional NMR "
    "spectra from a single experiment through machine learning. Nature "
    "Communications. 2025;16:10159. doi:10.1038/s41467-025-65294-x.",
    "[8] de Jong S. SIMPLS: an alternative approach to partial least squares "
    "regression. Chemometrics and Intelligent Laboratory Systems. "
    "1993;18:251-263.",
    "[9] Trygg J, Wold S. Orthogonal projections to latent structures (O-PLS). "
    "Journal of Chemometrics. 2002;16:119-128.",
    "[10] Rosipal R, Trejo LJ. Kernel partial least squares regression in "
    "reproducing kernel Hilbert space. Journal of Machine Learning Research. "
    "2001;2:97-123.",
    "[11] Mevik B-H, Wehrens R. The pls package: principal component and "
    "partial least squares regression in R. Journal of Statistical Software. "
    "2007;18:1-23.",
    "[12] Andersson CA. IKPLS: fast improved kernel partial least squares "
    "algorithms. Journal of Open Source Software. 2024;9:6533. "
    "doi:10.21105/joss.06533.",
    "[13] Pedregosa F, Varoquaux G, Gramfort A, et al. Scikit-learn: machine "
    "learning in Python. Journal of Machine Learning Research. "
    "2011;12:2825-2830.",
    "[14] Beurier G. nirs4all-methods: portable C++17 partial least-squares "
    "methods engine, version 1.0.18. 2026. https://methods.nirs4all.org/.",
    "[15] Halko N, Martinsson P-G, Tropp JA. Finding structure with randomness: "
    "probabilistic algorithms for constructing approximate matrix "
    "decompositions. SIAM Review. 2011;53:217-288.",
    "[16] Chen RJ, Ding T, Lu MY, et al. Towards a general-purpose foundation "
    "model for computational pathology. Nature Medicine. 2024;30:850-862. "
    "doi:10.1038/s41591-024-02857-3.",
    "[17] Xu H, Usuyama N, Bagga J, et al. A whole-slide foundation model for "
    "digital pathology from real-world data. Nature. 2024;630:181-188. "
    "doi:10.1038/s41586-024-07441-w.",
    "[18] Oquab M, Darcet T, Moutakanni T, et al. DINOv2: learning robust "
    "visual features without supervision. Transactions on Machine Learning "
    "Research. 2024.",
    "[19] Deng J, Dong W, Socher R, Li LJ, Li K, Fei-Fei L. ImageNet: a "
    "large-scale hierarchical image database. IEEE Conference on Computer "
    "Vision and Pattern Recognition. 2009:248-255. "
    "doi:10.1109/CVPR.2009.5206848.",
    "[20] Cacciatore S, Tenori L, Luchinat C, Bennett PR, MacIntyre DA. "
    "KODAMA: an R package for knowledge discovery and data mining. "
    "Bioinformatics. 2017;33:621-623. doi:10.1093/bioinformatics/btw705.",
    "[21] Cacciatore S, Luchinat C, Tenori L. Knowledge discovery by accuracy "
    "maximization. Proceedings of the National Academy of Sciences of the "
    "United States of America. 2014;111:5117-5122. "
    "doi:10.1073/pnas.1220873111.",
    "[22] NVIDIA Corporation. CUDA Toolkit documentation: cuBLAS, cuSOLVER and "
    "cuRAND libraries. https://docs.nvidia.com/cuda/.",
    "[23] Apple Inc. Metal Performance Shaders documentation. "
    "https://developer.apple.com/metal/Metal-Performance-Shaders/.",
    "[24] Krizhevsky A, Hinton G. Learning multiple layers of features from "
    "tiny images. Technical report. University of Toronto; 2009.",
]


def set_text(paragraph, text):
    paragraph.clear()
    paragraph.add_run(text)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("input")
    parser.add_argument("output")
    args = parser.parse_args()

    document = Document(args.input)
    paragraphs = document.paragraphs
    introduction = next(
        paragraph for paragraph in paragraphs
        if paragraph.text.strip().startswith("Partial least squares (PLS)")
    )
    set_text(introduction, INTRODUCTION)

    for prefix, replacement in REPLACEMENTS.items():
        paragraph = next(
            paragraph for paragraph in paragraphs
            if paragraph.text.strip().startswith(prefix)
        )
        if replacement is not None:
            set_text(paragraph, replacement)
        elif prefix == "SIMPLS follows de Jong's":
            set_text(paragraph, paragraph.text.replace("[3]", "[8]", 1))
        elif prefix == "OPLS applies response-orthogonal":
            text = paragraph.text.replace("[4]", "[9]", 1)
            set_text(paragraph, text.replace("[5]", "[10]", 1))
        elif prefix == "CPU routes are compiled C++":
            text = paragraph.text.replace("[11]", "[22]", 1)
            set_text(paragraph, text.replace("[12]", "[23]", 1))
        elif prefix == "The classification comparison used":
            set_text(paragraph, paragraph.text.replace("[15]", "[24]", 1))

    presentation = next(
        paragraph for paragraph in paragraphs
        if paragraph.text.strip().startswith("We present fastPLS")
    )
    element = OxmlElement("w:p")
    presentation._p.addprevious(element)
    pressure = Paragraph(element, presentation._parent)
    pressure.style = presentation.style
    pressure.add_run(
        "The same computational pressure arises from increasing spectral "
        "resolution, single-cell sample counts, foundation-model embeddings "
        "and repeated validation. KODAMA, for example, repeatedly fits "
        "cross-validated PLS discriminant models while maximizing predictive "
        "accuracy [20,21]."
    )

    reference_heading = next(
        index for index, paragraph in enumerate(paragraphs)
        if paragraph.text.strip() == "References"
    )
    reference_paragraphs = paragraphs[reference_heading + 1:]
    if len(reference_paragraphs) < len(REFERENCES):
        anchor = reference_paragraphs[-1]
        for _ in range(len(REFERENCES) - len(reference_paragraphs)):
            anchor = document.add_paragraph()
            reference_paragraphs.append(anchor)
    for paragraph, reference in zip(reference_paragraphs, REFERENCES):
        set_text(paragraph, reference)
    for paragraph in reference_paragraphs[len(REFERENCES):]:
        paragraph._element.getparent().remove(paragraph._element)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    document.save(output)


if __name__ == "__main__":
    main()
