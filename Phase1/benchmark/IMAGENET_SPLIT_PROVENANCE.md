# ImageNet/DINOv2 split provenance

The matched retrieval benchmark is an exploratory computational stress test,
not an evaluation on the canonical ImageNet training/validation split.

- Source archive: `imagenet_float32.RData`
- Samples: 1,281,167
- Features: 1,024 precomputed DINOv2 embedding values
- Classes: 1,000
- Split script: `benchmark/prepare_imagenet_float32_task.R`
- Split seed: 123
- Split rule: sample 1,000,000 row indices without replacement; use the
  complementary 281,167 indices as the development holdout
- Training/holdout overlap: 0
- Union of training and holdout indices: 1,281,167
- Task preparation time: `2026-07-22 17:04:41 SAST`

The exported feature archive contains the 1,281,167 pooled observations but
does not retain an authoritative canonical train/validation flag. The split is
therefore not described as the standard ImageNet split. PCA and PLS were fitted
only on the one-million-row training partition; the complementary rows were
projected after fitting. FAISS indices contained training rows only, and all
queries came from the complementary holdout.

The same development holdout had been examined during earlier ImageNet
experiments. The matched FAISS run fixed `k=10` and evaluated 50, 100, and 200
dimensions, but these choices were informed by that earlier exploration rather
than selected by nested validation. Its accuracy estimates are consequently
descriptive and cannot be interpreted as unbiased external generalization
performance. The 0.0005 absolute top-5 difference between the 200-dimensional
PLS representation and raw embeddings is not claimed as an improvement.

The archived source does not provide enough metadata to independently audit
the exact DINOv2 checkpoint, pooling rule, or possible overlap between the
encoder's pretraining corpus and ImageNet. Feature extraction was completed
before fastPLS benchmarking and was excluded from all reported timings.
