"""Build a source-mapped manuscript; never execute a PLS comparator."""
from pathlib import Path
import csv, json, statistics, re, subprocess
from docx import Document
from docx.shared import Inches, Pt
from docx.oxml import OxmlElement
from docx.oxml.ns import qn

ROOT = Path(__file__).resolve().parents[2]
PKG = ROOT/'fastPLS_fresh_github'
EXTRA = ROOT/'fastPLS-extra'
OPT = PKG/'benchmark_results/optimization_20260904'
REMOTE = EXTRA/'manuscript/evidence_audit_20260905/remote_saved'
OUT = EXTRA/'manuscript/corrected_20260905'
OUT.mkdir(parents=True, exist_ok=True)
LEDGER = {}
LEDGER['Illustrative NMR prediction artifact'] = {'source': str(PKG/'publication_results/0.99.39/current_release/nmr/fixed165_simpls_cuda_rsvd_k165_prediction.rds'), 'role': 'Saved predictions, not a newly fitted model'}

def read(path, role):
    with path.open() as f: data=list(csv.DictReader(f))
    LEDGER[role]={'source':str(path),'rows':len(data)}
    return data
def save(name, data):
    with (OUT/name).open('w',newline='') as f:
        w=csv.DictWriter(f,fieldnames=list(data[0]));w.writeheader();w.writerows(data)
def num(x):
    try:return float(x)
    except (ValueError,TypeError):return float('nan')
def fmt(x):
    v=num(x)
    if v!=v:return str(x) if x else 'Not recorded'
    return f'{v:.3g}'

rpanel=read(REMOTE/'pls_package_comparison_summary.csv','Figure 1A and Table S4: iterative comparison build, not public rSVD')
external=read(PKG/'publication_results/0.99.39/current_release/r_package_panel/pls_package_comparison_summary.csv','Figure 1A and Table S4: retained independent-package measurements')
fields=list(rpanel[0])
rpanel += [{k:r.get(k,'') for k in fields} for r in external if r['package'] != 'fastPLS']
ikcpu=read(PKG/'publication_results/0.99.39/current_release/ikpls_cross_language_cpu/ikpls_cross_language_summary.csv','Table S5: saved independent CPU IKPLS only')
ikgpu=read(PKG/'benchmark_results/ikpls_cross_language_20260825/ikpls_cross_language_cuda_summary.csv','Figure 1B and Table S5: saved IKPLS CUDA')
gpufast=[read(OPT/f'cuda/cifar_public_cuda_nocopy_rep{i}.csv',f'GPU fastPLS repeat {i}')[0] for i in (1,2,3)]
cuda=read(OPT/'publication_cuda_fold_reuse_v1/selected_backend/matched_cuda_summary.csv','Figure 2A and Table S6: CPU/CUDA matched source')
metal=read(OPT/'publication_metal_fold_reuse_v1/selected_backend/matched_metal_summary.csv','Figure 2B and Table S6: CPU/Metal matched source')
nmr=read(OPT/'float_factor_scores_nmr_summary/summary.csv','Table S8: CPU/float32 NMR source')
latest=read(OPT/'cpu_prediction_prefix_v2/nmr_summary/summary.csv','Figure 3 and Table S8: newer Metal float64 NMR source')
# Replace only matching route/precision/count rows, retaining each row's source.
key=lambda r:(r['family'],r['backend'],r['precision'],r['ncomp'])
nmrmap={key(r):dict(r,source_panel='precision_panel') for r in nmr}
for r in latest:nmrmap[key(r)]=dict(r,source_panel='later_Metal_float64_panel')
nmr=list(nmrmap.values())
save('nmr_merged_plot_values.csv',nmr)
selection=[];decisions=[]
for family in ['plssvd','simpls']:
    folder=OPT/f'metal_compact_path_v1/nmr_selection_{family}'
    for r in read(folder/'nmr_component_selection_summary.csv',f'Table S7 and Figure S2: {family} curve'):
        selection.append(dict(family=family,**r))
    for r in read(folder/'nmr_component_selection_decision.csv',f'{family} one-SE decision'):
        decisions.append(dict(family=family,**r))
save('nmr_selection.csv',selection)
image=read(REMOTE/'imagenet_current_summary.csv','Figure 4 and Table S9: later CUDA-requested hybrid ImageNet run')
save('imagenet_plot_values.csv',image)
deposited=read(PKG/'publication_results/0.99.39/current_release/nmr/figures/nmr_fixed165_summary.csv','Figure 3: deposited iterative PLS-SVD reference')
save('deposited_reference.csv',[r for r in deposited if r['label']=='Deposited PLS-SVD'])
save('r_panel.csv',rpanel)
save('cuda_selected.csv',cuda);save('metal_selected.csv',metal)
gpurows=[dict(method='fastPLS rSVD',call='repeat',time=statistics.median(num(r['total_sec']) for r in gpufast),accuracy=gpufast[0]['accuracy'])]
for r in ikgpu:
    if r['dataset']=='cifar100' and r['implementation'].startswith('IKPLS'):
        for call,field in [('first','median_cold_total_sec'),('repeat','median_warm_total_sec')]:
            gpurows.append(dict(method=r['implementation'],call=call,time=r[field],accuracy=r['accuracy']))
save('gpu_ikpls.csv',gpurows)
cpu_pred=read(OPT/'cpu_flash_summary/prediction_summary.csv','Table S3: fixed-factor prediction timings')
cpu_mem=read(OPT/'cpu_flash_summary/memory_summary.csv','Table S3: fixed-factor prediction memory')
paths=read(OPT/'publication_metal_fold_reuse_v1/component_paths/component_path_summary.csv','Figure S1 and attached table: full local component paths')
save('component_paths.csv',paths)

subprocess.run(['Rscript',str(EXTRA/'tools/plot_corrected_publication.R'),str(OUT),str(PKG)],check=True,
               env=__import__('os').environ|{'LANG':'en_US.UTF-8','LC_ALL':'en_US.UTF-8'})

def newdoc():
    d=Document();s=d.sections[0];s.page_width=Inches(8.27);s.page_height=Inches(11.69)
    s.top_margin=s.bottom_margin=Inches(.7);s.left_margin=s.right_margin=Inches(.7)
    normal=d.styles['Normal'];normal.font.name='Times New Roman';normal.font.size=Pt(11)
    normal.paragraph_format.space_after=Pt(6);normal.paragraph_format.line_spacing=1.15
    for style in ['Title','Heading 1','Heading 2']:
        d.styles[style].font.name='Times New Roman';d.styles[style].font.color.rgb=__import__('docx').shared.RGBColor(0,0,0)
    line=OxmlElement('w:lnNumType');line.set(qn('w:countBy'),'1');line.set(qn('w:restart'),'continuous');s._sectPr.append(line)
    p=s.footer.paragraphs[0];p.alignment=2
    field=OxmlElement('w:fldSimple');field.set(qn('w:instr'),'PAGE');p._p.append(field)
    return d
def p(d,text):return d.add_paragraph(text)
def h(d,text):d.add_heading(text,1)
def figure(d,file,caption):
    d.add_picture(str(OUT/file),width=Inches(6.7))
    d.paragraphs[-1].paragraph_format.keep_with_next=True
    q=p(d,caption)
    q.paragraph_format.line_spacing=1;q.runs[0].font.size=Pt(9)
def table(d,title,headers,rows):
    q=p(d,title);q.paragraph_format.keep_with_next=True;q.runs[0].bold=True
    t=d.add_table(rows=1,cols=len(headers));t.style='Light Shading Accent 1'
    for c,v in zip(t.rows[0].cells,headers):c.text=v
    repeat=OxmlElement('w:tblHeader');t.rows[0]._tr.get_or_add_trPr().append(repeat)
    for row in rows:
        for c,v in zip(t.add_row().cells,row):c.text=str(v)
    for row in t.rows:
        row._tr.get_or_add_trPr().append(OxmlElement('w:cantSplit'))
        for c in row.cells:
            for q in c.paragraphs:
                q.paragraph_format.space_after=Pt(2);q.paragraph_format.line_spacing=1
                if len(rows)<5:q.paragraph_format.keep_with_next=True
                for run in q.runs:run.font.size=Pt(8)
    return t

main=newdoc();supp=newdoc()
title='fastPLS: accelerated SIMPLS execution for high-dimensional biomedical data with optional CUDA and Metal routes'
main.add_heading(title,0)
p(main,'Dupe Ojo¹*, Alessia Vignoli²*, Stefano Cacciatore¹†, Leonardo Tenori²³†')
p(main,'¹ Bioinformatics Unit, International Centre for Genetic Engineering and Biotechnology, Cape Town, South Africa. ² Department of Experimental and Clinical Medicine, University of Florence, Italy. ³ Magnetic Resonance Center, University of Florence, Italy.')
p(main,'* Equal contributions. † Co-corresponding authors: Stefano Cacciatore, stefano.cacciatore@icgeb.org; Leonardo Tenori, tenori@cerm.unifi.it.')
h(main,'Abstract')
p(main,'Background and objective: High-dimensional partial least-squares (PLS) modelling can be limited by repeated component extraction and storage of large intermediate and prediction arrays. We developed fastPLS to accelerate SIMPLS-based biomedical workflows, with particular emphasis on multivariate nuclear magnetic resonance (NMR) prediction.')
p(main,'Methods: The implementation combines randomized singular value decomposition (rSVD), fresh per-component direction extraction, cached products and compact prediction. PLS-SVD, orthogonal PLS and kernel PLS share numerical infrastructure with SIMPLS. CPU execution and optional NVIDIA CUDA and Apple Metal routes support route-specific precision: CPU and CUDA accept float32 and float64, whereas native Metal execution uses float32. Independent-software comparisons are distinguished from numerical-reference validation and from approximate rSVD workflows.')
p(main,'Results: In the corrected NMR analysis, training-only selection retained 75 PLS-SVD and 50 SIMPLS components within the evaluated grid. Metal float64 fitting plus prediction required medians of 2.142 and 1.931 s, with held-out root mean squared deviation (RMSD) of 0.000729 and 0.000750, respectively. At a common 165-component workload, Metal PLS-SVD and SIMPLS required 3.322 and 4.760 s. In a separate CIFAR-100 GPU comparison, fastPLS required 0.667 s versus 1.480–1.552 s for repeated IKPLS calls, with accuracies of 70.94% and 70.95%. Memory and runtime benefits varied by precision, workload and retained outputs.')
p(main,'Conclusions: fastPLS reduces practical costs of sequential supervised dimension reduction through compiled numerical work and reduced intermediate storage. Approximate directions and backend-specific execution require numerical assessment; no universal speed ranking or precision advantage is inferred.')
h(main,'1. Introduction')
p(main,'Partial least squares (PLS) constructs latent variables that summarize predictor variation relevant to a response [1]. This is useful in biomedical studies with correlated predictors and more measured variables than samples. In metabolomics, the same framework supports classification from spectral profiles and prediction of continuous biological or analytical responses.')
p(main,'Predicting complete spectra creates a different computational problem from predicting a single clinical endpoint. A previous NMR workflow mapped 13,000 NOESY predictor bins to 28,355 diffusion-edited spectral intensities using 1,200 training spectra [2]. Its deposited fastsimpls function uses a PLS-SVD formulation: directions are derived from a singular value decomposition of the predictor–response cross-covariance. Repeated model selection and multivariate prediction can require substantially more work than one decomposition.')
p(main,'SIMPLS instead constructs sequential components using cross-covariance deflation and orthogonalization [3]. Existing implementations already provide component paths; avoiding separate refits for every prefix is therefore not itself a new SIMPLS estimator. Computational opportunities lie in how products, workspaces, coefficients and predictions are formed and retained. Randomized range approximation can reduce direction-extraction work [4], but its predictive consequences must be distinguished from exact numerical agreement.')
p(main,'Relevant software includes the R package pls [5] and Improved Kernel PLS implementations in IKPLS, which expose CPU and GPU workflows [6]. Orthogonal PLS (OPLS) removes predictor variation unrelated to the response [7], and kernel PLS extends modelling to nonlinear representations [8]. These algorithms and their returned objects differ, so speed comparisons must specify the estimator, solver and output contract.')
p(main,'We present fastPLS, an R package centred on optimized SIMPLS execution, with PLS-SVD, OPLS, kernel PLS, classification and nested validation. Large embedding matrices additionally motivate PLS as supervised feature extraction. ImageNet/DINOv2 embeddings [9] provide an engineering stress test of this matrix-processing stage, not evidence of biomedical predictive validity. The main contribution is the combination of compiled component updates, cached products and compact prediction, rather than a claim that every numerical route preserves an exact SIMPLS estimator.')
h(main,'2. Materials and methods')
main.add_heading('2.1 Numerical implementation',2)
p(main,'Let centred X ∈ ℝⁿˣᵖ contain predictors and Y ∈ ℝⁿˣᑫ responses. A is the maximum retained component count, C is the set of requested prefixes, J is the number of classes and K is the number of validation folds. Scaling uses training statistics only. Classification responses are dummy-coded, or evaluated through equivalent class products where supported.')
p(main,'For PLS-SVD, the predictor–response cross-covariance S = XᵀY is approximated once by UDVᵀ. With scores Tₐ = XUₐ, fastPLS forms the score Gram matrix once, reuses its leading blocks, solves (TₐᵀTₐ)Hₐ = DₐVₐᵀ, and predicts XnewUₐHₐ before restoring the training-response mean. Response rank limits the available components. Algorithm 2 separates this one-shot decomposition from the sequential SIMPLS execution in Algorithm 1.')
p(main,'The accelerated SIMPLS route updates normalized scores, response loadings and the deflated cross-covariance entirely within its selected numerical backend. At each refresh, a randomized range calculation starts from a new random sketch of the current deflated operator. Eligible large classification problems generate up to eight candidate directions in one refresh and consume them sequentially; other shapes refresh one direction for each component. Candidate reuse changes the approximation schedule but does not use the preceding component as a warm start. The implementation also reuses the deflation row product, retains score and factor workspaces, updates requested prediction prefixes incrementally, and predicts through compact latent factors.')
table(main,'Algorithm 1. Accelerated SIMPLS component execution',['Step','Operation'],[
 ['1. Initialize','Using training statistics, centre or scale X and centre Y. Form S₀ = XᵀY, or define the equivalent implicit products. Initialize empty matrices R, T, Q and V.'],
 ['2. Refresh directions','Draw a new random sketch for the current Sₐ. Compute one candidate direction, or a block D on eligible large classification problems. No previous component initializes this sketch.'],
 ['3. Form a score','Select the next candidate r; orthogonalize it against retained directions, calculate t = Xr, correct t and r against retained scores and weights, and normalize both using ‖t‖₂.'],
 ['4. Update loadings','Calculate p = Xᵀt and q = Yᵀt. For classification, calculate q directly from class sums without materializing a dense one-hot response.'],
 ['5. Define deflation','Orthogonalize p against V and normalize it to obtain v. Calculate the deflation row h = vᵀSₐ once.'],
 ['6. Deflate','Update Sₐ₊₁ = Sₐ − vh, append r, t, q and v, and reuse allocated workspaces. If a candidate block is active, continue with its next column before refreshing.'],
 ['7. Retain prefixes','For each requested component count c ∈ C, retain compact factors or update requested fitted/prediction summaries without rebuilding earlier prefixes.'],
 ['8. Predict','For a new matrix, apply the stored training transformation, calculate Tnew = XnewR, and obtain Ŷ = TnewQᵀ + 1ȳᵀ.']])
table(main,'Algorithm 2. PLS-SVD fitting and prediction',['Step','Operation'],[
 ['1. Preprocess','Using training statistics, centre or scale X and centre Y. For classification, represent Y through class sums and class proportions.'],
 ['2. Cross-covariance','Form S = XᵀY, or apply the equivalent operator products when the implicit route is selected.'],
 ['3. Low-rank decomposition','Calculate the retained approximation S ≈ UDVᵀ once, using the selected low-rank solver and precision.'],
 ['4. Training scores','Calculate T = XU and cache G = TᵀT and C = UᵀS.'],
 ['5. Prefix coefficients','For each requested c ∈ C, solve G₁:c,₁:c Hc = C₁:c,: by Cholesky factorization and triangular solves; do not form an explicit inverse.'],
 ['6. Predict','Transform Xnew using the training statistics, calculate Tnew,c = XnewU₁:c, and obtain Ŷc = Tnew,c Hc + 1ȳᵀ.']])
p(main,'Matrix-free products evaluate SΩ = Xᵀ(YΩ) and SᵀQ = Yᵀ(XQ), avoiding explicit p × q storage. This reduces storage but can increase repeated data access. OPLS filters orthogonal predictor components before fitting the predictive core. Linear kernel PLS uses a linear shortcut; nonlinear kernels form centred training Gram matrices and therefore require quadratic sample-size storage. The supplementary algorithms specify these operations and their route limitations.')
main.add_heading('2.2 Solvers, classification and backends',2)
p(main,'Native rSVD is the current public solver. Ordinary controls use 32 oversampling directions and five power iterations; response- and class-specific profiles can use 48/6 or 64/7. The massive SIMPLS profile records 12/2 and uses a fresh rank-one direction update. Effective controls must be interpreted together with the executed direction rule. Iterative-SVD rows in independent numerical comparisons belong to a separate reference build, not the current rSVD-only interface. Finite-factor diagnostics do not establish agreement with an independent estimator.')
p(main,'Argmax assigns the class with the largest predicted response. Latent-score LDA computes class means μⱼ and pooled covariance Σ = [TᵀT − Σⱼ nⱼμⱼμⱼᵀ]/max(1,n−J). It solves (Σ + ρsI)wⱼ = μⱼ by Cholesky and triangular solves, with s = tr(Σ)/d when positive and finite, otherwise one. The fallback sequence is ρ = 10⁻⁸, 10⁻⁶, 10⁻⁵, 10⁻⁴, 10⁻³, 10⁻². The discriminant is δⱼ(t) = tᵀwⱼ − ½μⱼᵀwⱼ + log(nⱼ/n). No covariance inverse is explicitly formed.')
p(main,'CPU routes use compiled code and BLAS/LAPACK; multithreading depends on the linked BLAS and workload. The resident CUDA SIMPLS and PLS-SVD routes use cuBLAS, cuSOLVER and cuRAND for preprocessing, response products, randomized decomposition, score formation, orthogonalization, deflation, prediction and LDA. The native Metal float32 SIMPLS route uses Metal Performance Shaders matrix products and custom Metal kernels for preprocessing, label-aware cross-products, component updates, compact prediction, response metrics and regularized LDA; fitted factors and reusable prediction workspaces remain in device-accessible buffers. Only requested results and scalar status values return to R. Unsupported accelerator combinations raise an error rather than falling back to CPU. Standard R numeric matrices use float64, whereas float-package matrices select float32. Apple Metal does not expose native float64 arithmetic, so Metal rejects float64 input rather than executing host numerical stages. Halving input representation size does not imply halving complete-process memory or runtime.')
main.add_heading('2.3 Datasets and benchmark contracts',2)
p(main,'The benchmark comprises CCLE, CIFAR-100, GTEx v8, MetRef, Retina, Tabula Muris, TCGA-BRCA, TCGA-HNSC methylation, TCGA Pan-Cancer, CBMC CITE-seq, PRISM and NMR; ImageNet is an additional stress test. Dataset construction, preprocessing, dimensions and acquisition restrictions are given in Supplementary Section S1. Fixed prepared splits permit paired computational comparisons but do not establish donor-level generalization when subject identifiers are unavailable.')
p(main,'Comparisons preserve split, preprocessing, precision, components and prediction endpoints within each matched panel. The iterative SIMPLS software comparison and the rSVD backend panel answer different questions and are not pooled. Saved independent-package and IKPLS measurements were reused rather than rerun. The current rSVD-only package does not yet have a complete matched CPU comparison against every independent implementation; no overall CPU superiority claim is made from those reference rows.')
p(main,'Fitting and held-out prediction are timed separately where available. Repetition counts and dispersion accompany the corresponding tables. GPU timing includes the measured public workflow and synchronization; first-call IKPLS timings are distinct from repeated calls. Absolute process RSS includes the runtime and data. Incremental RSS subtracts a recorded baseline and remains a process-level measure; GPU increments may include context and allocator state. All memory is reported in MiB. Individual failures and missing measurements remain visible.')
p(main,'Classification accuracy is the fraction of correctly decoded labels; balanced accuracy averages class recalls, and top-5 accuracy tests membership among five ranked classes. RMSD is the square root of the mean squared response error. Independent-test Q² uses the training-response mean as the baseline; CV Q² uses fold-training means. Training R² is descriptive and is not used to select components. Numerical comparisons, conditional predictive uncertainty and timing repetitions are distinct evidence classes.')
main.add_heading('2.4 NMR and ImageNet analyses',2)
p(main,'The NMR benchmark uses 1,200 training and 321 held-out spectra, 13,000 predictors and 28,355 responses. Predictor columns strictly between 4.6 and 4.8 ppm are zeroed in training and test matrices before selection; responses are unmasked and all response columns enter the reported metrics. Five paired training-only splits and a one-standard-error rule select the smallest eligible component count. The grid and complete eligibility sets appear in Table S7. Corrected PLS-SVD scoring uses its latent-response weights, not the SIMPLS response-loading formula. Model selection and the common-165-component computational comparison are reported separately.')
p(main,'The ImageNet matrix contains 1,281,167 DINOv2 embedding rows, 1,024 predictors and 1,000 labels, split into 1,000,000 training and 281,167 held-out rows using seed 123. This is not the canonical ImageNet split. Exact representation-extraction provenance is incomplete, and the held-out data had informed earlier component exploration. The experiment is therefore a single-run feasibility study, not a confirmatory accuracy comparison. Timing covers a maximal model and its complete requested prefix path; the same total must not be counted as a separate fit at every component.')
h(main,'3. Results')
main.add_heading('3.1 Comparison with independent implementation',2)
p(main,'Independent R implementations and IKPLS expose different computational trade-offs. Figure 1A regenerates the latest retrieved R-package comparison values, explicitly identifying the iterative fastPLS comparison build. These results are informative about compiled execution and retained objects, but do not measure the current public rSVD-only solver. The full rows, metrics, repetition counts and memory values are retained in Table S4. Consequently, the previously reported universal or near-universal speed ranking is not carried into the present conclusions.')
p(main,'The matched 50-component CIFAR-100 CUDA rSVD workflow completed in 0.666, 0.667 and 0.668 s with 70.94% accuracy. Saved IKPLS GPU repeat-call medians were 1.480 and 1.552 s for its two formulations, with 70.95% accuracy; first-call medians were 1.859 and 1.861 s (Figure 1B). The repeat-call ratios are approximately 2.22 and 2.33. The 0.01-percentage-point accuracy difference is not interpreted as predictive superiority. Saved IKPLS CPU results remain separate because a fully matched latest-source fastPLS CPU result panel is not available.')
figure(main,'figure1.png','Figure 1. Independent-implementation comparisons. A: latest retrieved R-package workflow table; cell values show accuracy, total time in seconds and absolute process RSS in MiB in separate panels. The fastPLS rows use the iterative comparison build, not the current public rSVD-only route. B: separate CIFAR-100 GPU rSVD/IKPLS comparison at 50 components. IKPLS first and repeat calls are distinguished; fastPLS has three repeat-call measurements. Estimators and hardware differ between A and B; their values are not pooled.')
main.add_heading('3.2 Execution and storage improvements',2)
p(main,'The optimized numerical code retains candidate-geometry batching, suitable cross-product caches, deflation-product reuse and PLS-SVD score-Gram reuse. Compact prediction reuses existing scores and response weights instead of copying or recomputing each prefix. In a fixed-factor wide-response experiment, SIMPLS prediction decreased from 6.95 to 5.40 ms, and stored-weight PLS-SVD from approximately 7.20 to 5.80 ms, without changes in the compared predictions. Separate prediction-memory runs reduced median process increments from 128.97 to 39.55 MiB for SIMPLS and from 69.16 to 10.33 MiB for PLS-SVD (Table S3). These are prediction-stage benefits, not whole-fit or IKPLS speedups.')
p(main,'Figure 2 regenerates CPU/accelerator runtime ratios from the completed selected-point tables. Each accelerator is compared with its paired CPU workstation run, rather than comparing the two computers directly. Ratios below one denote an accelerator slowdown. The complete paired metrics and memory remain in Table S6; runtime ratios alone do not establish numerical agreement. Shared-core extraction tests verify selected numerical outputs but do not replace a final common-source all-dataset timing campaign.')
figure(main,'figure2.png','Figure 2. CPU/accelerator fitting-plus-prediction runtime ratios from the selected-point panels. A: CUDA; B: Metal. Values above one favor the accelerator. All available ratios are displayed, without hiding metric differences. The paired metrics, component counts, repetitions and memory are in Table S6; missing pairs remain unreported. CPUs are paired within each workstation, not across hardware.')
main.add_heading('3.3 Multivariate NMR prediction',2)
p(main,'Correcting PLS-SVD scoring changed the selected component count from five to 75; the earlier five-component conclusion is invalid for the corrected scoring path. SIMPLS selected 50 components. Both are smallest values within one standard error of the best mean validation RMSD on the evaluated grid, not global optima. PLS-SVD eligibility comprised 75, 100, 125, 150, 165, 175, 200 and 250; SIMPLS eligibility comprised 50, 75 and 100 (Figure S2 and Table S7).')
p(main,'At their selected component counts, the latest Metal float64 endpoint panel gave RMSD 0.000729222 in 2.142 s for PLS-SVD and RMSD 0.000750016 in 1.931 s for SIMPLS. At a common 165 components, the corresponding times were 3.322 and 4.760 s, with RMSD 0.000785888 and 0.000936848. These summaries use three seeds and three timing repetitions per seed. The former Metal PLS-SVD timings of 6.657 s at 50 components and 25.283 s at 165 components do not describe this improved implementation.')
p(main,'The deposited iterative PLS-SVD implementation required 457.511 s at 165 components with RMSD 0.000785806 under its recorded CPU workflow. This is a separate reference workload: solver, hardware and implementation differ from the new Metal rows, so the ratio is not an isolated implementation speedup. Separate repeated CUDA SIMPLS calls gave medians of 0.707 and 1.797 s at 50 and 165 components. Their replication structure differs from the three-seed Metal panel and is not pooled with it.')
p(main,'Precision effects were route dependent. The CPU precision panel showed lower process-memory increments for float32 SIMPLS but slower execution than float64. Later Metal float64 PLS-SVD improvements substantially reduced the apparent float32 speed advantage. A precision comparison must therefore use paired builds and numerical settings, rather than contrasting the newest float32 result with a superseded float64 implementation. Table S8 retains the source-specific measured endpoints and identifies the remaining mismatch. Figure 3 separates current endpoint timings from the saved illustrative spectrum.')
figure(main,'figure3.png','Figure 3. NMR computation and prediction. A–C: fitting plus prediction time, RMSD and incremental host RSS for Metal float64 at 165 components and the deposited CPU iterative reference; this is not a solver- or hardware-isolated comparison. D: per-spectrum RMSD distribution from the saved CUDA prediction artifact. E–F: observed and predicted held-out spectrum over 12–0 and 1.7–0.5 ppm from that artifact, choosing the sample nearest its median per-spectrum RMSD. These illustrative predictions were not regenerated by the latest Metal timing workers and are not presented as their output. Training-selection results are shown separately in Figure S2.')
main.add_heading('3.4 Foundation-model embedding feasibility',2)
p(main,'The later ImageNet run requested CUDA but recorded hybrid host SIMPLS/CUDA rSVD execution and model_gpu_resident = FALSE. Figure 4 and Table S9 use this run rather than the older faster timing table. Both argmax and LDA paths contain ten prefixes from 100 to 1,000 components. Their recorded end-to-end totals cover maximal-model fitting and the complete prefix-scoring stage, not independent fits at each displayed point. This experiment demonstrates feasibility with the reported memory footprint, not full GPU residency or superiority over a matched IKPLS GPU ImageNet run.')
figure(main,'figure4.png','Figure 4. Later ImageNet hybrid CPU/CUDA float32 experiment. A: held-out top-1 and top-5 accuracy across requested prefixes. B: total measured path time by classifier. C: recorded peak process RSS and peak device memory. Each head has one measured maximal-model run; repeated totals across prefixes are not independent timings. The noncanonical split contains 1,000,000 training and 281,167 held-out rows. Results are exploratory; 1,000 components is a boundary stress point.')
h(main,'4. Discussion')
p(main,'The practical gains arise from reducing repeated numerical work and retained intermediate storage. In SIMPLS, matrix batching changes the balance between matrix-vector and matrix-matrix operations. Compact factors are especially important when a dense coefficient path would scale with predictor dimension, response dimension and requested prefixes. PLS-SVD additionally reuses its score Gram matrix. None of these mechanisms implies uniform acceleration: repeated implicit products can be slower than an explicit cross-covariance, small workloads may not amortize accelerator overhead, and the retained-output contract can dominate complete-workflow comparisons.')
p(main,'The NMR case illustrates why computation and model selection must remain separate. The selected PLS-SVD and SIMPLS models have different component counts, whereas the common-165-component workload addresses execution cost. The corrected PLS-SVD selection also demonstrates the importance of using the family-specific latent prediction map. Large changes in timing should be interpreted against their exact source and operation profile, rather than attributed solely to solver name or precision.')
p(main,'Randomized directions are approximate and may depend on seed, conditioning and component count. Candidate blocks do not generally reproduce an independently solved exact leading direction after every deflation. Numerical-reference checks and predictive comparisons are therefore reported as separate evidence, with no universal estimator-preservation claim for the batched route. Float32 input savings are likewise distinct from process-memory savings and acceptable prediction error.')
p(main,'The current evidence has limits. The optimized rSVD-only source does not yet have a complete estimator/output-matched CPU comparison against all independent packages. Some panels use different development snapshots and cannot establish one frozen-release performance profile. The ImageNet experiment is a hybrid, single-run feasibility measurement with incomplete embedding provenance. These limitations preclude universal software rankings, blanket GPU-residency claims and general float32 speed claims, but do not negate the measured execution and storage improvements.')
h(main,'5. Conclusions')
p(main,'fastPLS provides compiled SIMPLS-based modelling with reusable matrix products, compact prediction, related PLS families and optional accelerator routes. The corrected NMR analysis demonstrates practical high-response prediction, while stage-level measurements identify concrete storage and computation savings. Performance claims remain conditional on numerical settings, hardware and output contracts.')
h(main,'Declarations')
p(main,'Acknowledgements: The authors thank the University of Cape Town’s ICTS High Performance Computing team for providing a high-performance computing facility for this study (https://ucthpc.uct.ac.za/).')
p(main,'Funding: This research received no specific grant from funding agencies in the public, commercial or not-for-profit sectors. Competing interests: The authors declare no competing financial interests or personal relationships that could have influenced this work.')
p(main,'Data and software availability: Development sources are available at https://github.com/tkcaccia/fastPLS. The Bioconductor submission is tracked at https://github.com/Bioconductor/BiocContributions/issues/84. The package-wide licensing transition is not yet complete. GPL-dependent comparison tools and manuscript evidence are separated in fastPLS-extra. Dataset access conditions and per-analysis result sources accompany the supplement; no immutable final-release benchmark is asserted.')
h(main,'References')
oldmain=Document(PKG/'artifacts/CMPB_rewrite_20260903_cycle138/fastPLS_CMPB_main_0.99.39.docx')
refs={int(m.group(1)):q.text for q in oldmain.paragraphs if (m:=re.match(r'^\[(\d+)\]',q.text))}
for i,j in enumerate([1,7,11,16,17,34,12,14,29],1):p(main,re.sub(r'^\[\d+\]',f'[{i}]',refs[j]))

supp.add_heading('Supplementary material',0);p(supp,title)
h(supp,'S1. Datasets and preprocessing')
p(supp,'This supplement consolidates numerical methods and measured evidence without copying the superseded figure or table values. The attached source ledger distinguishes the generating campaign for every table. A shared version string does not imply identical source code across development builds.')
old=Document(PKG/'artifacts/CMPB_rewrite_20260903_cycle138/fastPLS_CMPB_supplement_0.99.39.docx')
active=False
for q in old.paragraphs:
    if q.text.startswith('S5. Real datasets'):active=True;continue
    if q.text.startswith('S6. Synthetic'):active=False
    if active and q.text and not q.text.startswith(('Table ','S5.')):
        text=re.sub(r'\[[\d,– -]+\]','',q.text)
        text=re.sub(r'Table S\d+','the dataset manifest',text)
        p(supp,text)
prepared = next(t for t in old.tables if any('Prepared n train' in c.text for c in t.rows[0].cells))
dataset_rows = [[c.text for c in row.cells] for row in prepared.rows]
table(supp,'Table S1. Dataset dimensions from the prepared benchmark panel',dataset_rows[0],dataset_rows[1:])
LEDGER['Table S1: unchanged prepared-data dimensions'] = {'source': str(PKG/'artifacts/CMPB_rewrite_20260903_cycle138/fastPLS_CMPB_supplement_0.99.39.docx'), 'role': 'Prepared-data metadata, not new timing measurements'}
p(supp,'Splits are computational unless subject-level separation is explicitly documented. The NMR protocol uses 1,200/321 rows, 13,000 predictors, 28,355 responses, and predictor-only zeroing strictly between 4.6 and 4.8 ppm.')
h(supp,'S2. Numerical algorithms and capabilities')
p(supp,'For PLS-SVD, S ≈ UDVᵀ and Tₐ = XUₐ. The cached route solves (TₐᵀTₐ)Hₐ = DₐVₐᵀ; coefficient matrices are UₐHₐ. SIMPLS follows Algorithm 1 in the main text. A block supplies approximate candidates from the current state at refresh; within-block reuse is not an exact fresh leading-direction solve after each deflation. CPU eligible classification batching requires q > 1, q ≤ 2,048, at least four requested components and npq ≥ 5×10⁸. CUDA adds n ≥ 5,000 and at least 50 requested components. The block is bounded by eight and remaining dimensions.')
p(supp,'For OPLS, obtain a predictive direction w, set t = Xw and p = Xᵀt/(tᵀt), and normalize wₒ = p − w(wᵀp)/(wᵀw). Then tₒ = Xwₒ, pₒ = Xᵀtₒ/(tₒᵀtₒ), and X is replaced by X − tₒpₒᵀ before the next filter. Stored filters are applied to test predictors. The R float64 CPU filtering callback retains a dense decomposition; the standalone wrapper uses rSVD. Public rSVD-only dispatch therefore does not mean every internal reduced operation is randomized.')
table(supp,'Algorithm S1. OPLS filtering and predictive fitting',['Step','Operation'],[
 ['1. Preprocess','Apply training-derived centring or scaling to X and centre Y.'],
 ['2. Predictive direction','Calculate a response-associated predictor direction w from the current XᵀY operator and normalize it.'],
 ['3. Orthogonal direction','Calculate t = Xw and p = Xᵀt/(tᵀt), then remove the projection of p onto w: wₒ = p − w(wᵀp)/(wᵀw). Normalize wₒ.'],
 ['4. Orthogonal deflation','Calculate tₒ = Xwₒ and pₒ = Xᵀtₒ/(tₒᵀtₒ), then update X ← X − tₒpₒᵀ. Repeat for the requested number of orthogonal components.'],
 ['5. Predictive model','Fit the selected PLS-SVD or SIMPLS predictive core to the filtered X and Y.'],
 ['6. Held-out prediction','Apply the stored training transformation and orthogonal filters to Xnew before using the predictive PLS factors.']])
p(supp,'Nonlinear kernels use exp(−γ‖xᵢ−xⱼ‖²) or (γxᵢᵀxⱼ+c)ᵈ. Training centring is HKH, H = I − 11ᵀ/n. A held-out kernel row subtracts its own mean and the stored training column means and adds the training grand mean. One dense Gram matrix costs 4n² bytes in float32 or 8n² in float64 before copies, centring and workspaces; no universal safe sample-size limit follows from this lower bound.')
table(supp,'Algorithm S2. Kernel PLS fitting and prediction',['Step','Operation'],[
 ['1. Predictor transformation','Apply training-derived centring or scaling to X.'],
 ['2. Training kernel','Calculate Kij = xiᵀxj for the linear kernel, exp(−γ‖xi−xj‖²) for the radial-basis kernel, or (γxiᵀxj + c)d for the polynomial kernel.'],
 ['3. Kernel centring','Store the training column means and grand mean, and calculate Kc = HKH with H = I − 11ᵀ/n.'],
 ['4. Latent model','Use Kc as the predictor representation and fit the selected PLS core for each requested component prefix.'],
 ['5. Test kernel','Calculate Knew between Xnew and training predictors; subtract its row means and the stored training column means, then add the stored grand mean.'],
 ['6. Predict','Project the centred test kernel through the retained latent factors and restore the training-response mean.']])
p(supp,'LDA uses the covariance, regularization sequence and discriminant in Section 2.2. CPU float64 uses LAPACK; the public non-Windows float32 route retains a reusable Cholesky workspace. The experimental float32 LAPACK alternative is not claimed as a universal replacement: a singular-covariance test showed approximately 1.96% weight disagreement despite small backward errors. CUDA uses cuBLAS products and cuSOLVER Cholesky. The native Metal float32 path forms class means and pooled covariance on the GPU and applies the same scale-normalized ridge sequence through Metal Performance Shaders Cholesky factorization and triangular solving.')
table(supp,'Table S2. Storage and operation summary',['Operation','Dominant object/work','Qualification'],[
 ['Explicit cross-covariance','pq entries; O(npq) product','May be preferable when it fits and is reused'],
 ['Implicit cross-covariance','X, Y and low-rank workspaces; repeated O(n(p+q)ℓ) products','Avoids pq storage, not necessarily faster'],
 ['Compact prediction','R: pA; Q: qA; blocked test scores','Dense coefficient path can instead require pq times number of prefixes'],
 ['PLS-SVD score-Gram cache','A² Gram entries; one score cross-product','Reuses leading blocks; does not remove prefix solves'],
 ['Nonlinear kernel PLS','n² Gram entries plus workspaces','Host/accelerator stages are route dependent'],
 ['LDA','d² covariance and dJ weights','Requires conditioning/regularization checks']])
h(supp,'S3. Execution-stage measurements')
table(supp,'Table S3. Fixed-factor rSVD prediction-stage comparison',['Case','Before ms','After ms','Ratio','Relative prediction error'],[
 [r['case'],fmt(num(r['before_median_sec'])*1000),fmt(num(r['after_median_sec'])*1000),fmt(r['before_over_after_ratio']),fmt(r['max_relative_prediction_error'])]
 for r in cpu_pred if r['solver']=='rsvd'])
p(supp,'These measurements use identical saved model factors and forward/reverse timing orders, not independent refits. Forty batches were summarized per candidate and case. The separate memory experiment used p=200, q=8,000, 96 stored components, 16 requested prefixes and eight test rows. SIMPLS process increments were 128.97/39.55 MiB before/after; PLS-SVD increments were 69.16/10.33 MiB. These are sampled process measurements, not isolated allocation counts.')
h(supp,'S4. Independent implementations')
table(supp,'Table S4. Latest retrieved independent R workflow rows',['Dataset','Method','A','Reps','Time s [IQR]','Accuracy','Peak RSS MiB'],[
 [r['dataset'],r['method_id'],r['ncomp_requested'],r['reps_ok'],f"{fmt(num(r['median_time_ms'])/1000)} [{fmt(num(r['iqr_time_ms'])/1000)}]",fmt(r['median_metric']),fmt(r['median_peak_host_rss_mb'])] for r in rpanel])
p(supp,'The fastPLS iterative rows belong to the comparison build. They are not presented as the current public rSVD-only package. Different classifiers and algorithms are end-to-end workflows, not estimator-equivalent comparisons. Source tables retain missing rows and failures; absent values are not interpreted as zero cost.')
table(supp,'Table S5. Independent IKPLS measurements and matched CIFAR-100 GPU fastPLS',['Dataset','Implementation','Call','Time s','Accuracy'],
 [[r['dataset'],r['implementation'],'CPU',fmt(r['median_total_sec']),fmt(r['accuracy'])] for r in ikcpu if r['implementation'].startswith('IKPLS')]+
 [['cifar100',r['method'],r['call'],fmt(r['time']),fmt(r['accuracy'])] for r in gpurows])
h(supp,'S5. Backend comparisons and component paths')
table(supp,'Table S6. Completed selected-point CPU/accelerator panel',['Workstation','Dataset','Family','Backend','A','Reps','Time s','Metric','RSS Δ MiB'],[
 [host,r['dataset'],r['method'],r['backend'],r['ncomp'],r['n_ok'],fmt(r['median_total_sec']),fmt(r['median_metric']),fmt(r['median_incremental_rss_mb'])] for host,data in [('CUDA',cuda),('Metal',metal)] for r in data])
p(supp,'Each panel retains its generating snapshot. Metrics are classification accuracy or task-specific RMSD; their units and preprocessing are described in S1. Ratios are paired within a workstation. Completed local component paths are supplied as component_paths.csv and displayed in Figure S1. These paths are descriptive held-out measurements, not a new tuning procedure.')
figure(supp,'figureS1.png','Figure S1. Component-path runtime on all available local datasets. CPU and Metal are paired within the local campaign. Curves distinguish PLS families; full prediction, memory, dispersion, controls and failures remain in component_paths.csv. They are not pooled with another source snapshot.')
h(supp,'S6. NMR selection and endpoint measurements')
p(supp,'Both families were evaluated on five paired training-only splits. The grid is 1, 2, 3, 5, 10, 25, 50, 75, 100, 125, 150, 165, 175, 200, 250 and 300. For each a, compute the mean validation RMSD mₐ. Let a* minimize mₐ; the threshold is mₐ* + sd(RMSD across five splits at a*)/√5. Retain all grid values below this threshold and choose the smallest. Test responses never enter this rule. Correct family-specific latent coefficients are required for PLS-SVD scoring.')
table(supp,'Table S7. Corrected one-standard-error decisions',['Family','Mean minimum A','Selected A','Threshold','Eligible A'],[
 [r['family'],r['minimum_mean_ncomp'],r['selected_ncomp'],fmt(r['one_se_threshold']),r['eligible_ncomp']] for r in decisions])
figure(supp,'figureS2.png','Figure S2. Corrected training-only NMR component selection. Lines show mean validation RMSD, vertical bars its standard error across five paired splits, and dotted horizontal lines the one-standard-error threshold. PLS-SVD selects 75 and SIMPLS 50 components within the evaluated grid. Neither result is described as an unconstrained optimum.')
table(supp,'Table S8. NMR endpoint results with source-specific precision panels',['Family','Backend','Precision','A','Time s [IQR]','RMSD','RSS Δ MiB'],[
 [r['family'],r['backend'],r['precision'],r['ncomp'],f"{fmt(r['median_total_sec'])} [{fmt(r['iqr_total_sec'])}]",fmt(r['median_RMSD']),fmt(r['median_incremental_rss_mib'])] for r in nmr])
p(supp,'All rows use seeds 123–125 with three timing repeats per seed and separate memory workers. Metal float64 rows are replaced by the later completed endpoint panel, including 75 components; CPU and float32 rows retain their explicitly identified precision-panel source. They must not be used for a final same-build precision speedup claim. Oversampling/power are 32/5 for PLS-SVD and 12/2 for massive SIMPLS, with the executed rank-one rule recorded. The source-labelled nmr_merged_plot_values.csv preserves controls and replication.')
h(supp,'S7. ImageNet')
table(supp,'Table S9. Later hybrid float32 ImageNet run',['Head','A','Top-1','Top-5','Whole path s','Peak host MiB','Peak GPU MiB'],[
 [r['classifier'],r['ncomp_requested'],fmt(r['top1_accuracy']),fmt(r['top5_accuracy']),fmt(r['total_time_sec']),fmt(r['process_peak_rss_mb']),fmt(r['gpu_peak_mb'])] for r in image])
p(supp,'Each classifier was fitted once at its maximal component count and evaluated over the prefix path. Repeated total-time and memory entries describe the same maximal run, not ten independent fits. The record identifies hybrid_host_simpls_cuda_rsvd and model_gpu_resident=FALSE. Its incremental host metric is not an isolated fitting allocation: readers should use the retained baseline columns in imagenet_plot_values.csv. The exact checkpoint, pooling and image-to-row map are not independently recoverable from the prepared matrix. This limits reproducibility and clinical interpretation.')
h(supp,'S8. Validation and source mapping')
p(supp,'Refactoring checks on the shared native core verified saved public CPU/Metal metric paths at 10⁻¹² and selected rSVD spectra at 10⁻⁷. The latest LDA extraction build completed 1,847 assertions with no failures, errors or test warnings and 24 skips. These are software regression checks, not new all-dataset estimator qualification or timing evidence. Final package-wide R CMD check, BiocCheck and common-source benchmark regeneration remain separate requirements. No old numerical-equivalence count is attributed to an untested new candidate route.')
p(supp,'source_ledger.json identifies each input CSV. All main figures and numerical tables in this corrected document are generated by build_corrected_publication.py and plot_corrected_publication.R; no old image asset is reused. The illustrative spectrum alone uses an identified saved prediction artifact, not a newly executed fit. Independent software was not rerun. The complete raw output CSVs are preserved alongside the documents, including precision, controls, errors and source-specific memory definitions.')
main.save(OUT/'fastPLS_manuscript_corrected.docx');supp.save(OUT/'fastPLS_supplement_corrected.docx')
(OUT/'source_ledger.json').write_text(json.dumps(LEDGER,indent=2)+'\n')
print(OUT)
