# Leakage-Free Sufficient-Statistics Cross-Validation

This pseudocode mirrors the compiled cross-validation route in
`inst/include/fastpls/core/cross_validation.hpp`. Caching is enabled only when
the fold map covers every row and the storage/work guard accepts the relevant
statistic. Otherwise, the implementation computes the same quantities directly
from each training fold.

```text
CV(X, Y_or_labels, fold, components, family, scaling, head, backend, seed):
    validate_inputs_and_grouped_fold_map()
    cache = eligible_additive_statistics(X, Y_or_labels)

    for h in 1..number_of_folds:
        H = rows with fold == h
        T = all rows except H

        train_marginals = cache.marginals - aggregate_rows(H)
        center, scale, response_mean = preprocess_from(train_marginals)
        X_holdout = apply_training_preprocessing(X[H, ], center, scale)

        if regression and cached(X_transpose_Y):
            crosscov_T = cache.X_transpose_Y - transpose(X[H, ]) * Y[H, ]
            crosscov_T = center_scale_with_training_statistics(crosscov_T)
        else if classification and cached(class_sums):
            class_count_T = cache.class_count - class_count(H)
            class_sum_T = cache.class_sum - class_sum(H)
            crosscov_T = label_crosscovariance(class_count_T, class_sum_T)
        else:
            crosscov_T = crosscovariance_from_rows(T)

        if cached(X_transpose_X):
            gram_X_T = cache.X_transpose_X - transpose(X[H, ]) * X[H, ]
            gram_X_T = center_scale_with_training_statistics(gram_X_T)

        if cached(Y_Y_transpose):
            gram_Y_T = principal_submatrix(cache.Y_Y_transpose, T)
            training_row_sums = cache.row_sums[T] - sums_against(H)
            gram_Y_T = double_center(gram_Y_T, training_row_sums)

        if family is nonlinear_kernel_PLS:
            build_and_center_training_kernel_from_rows(T)
            build_and_center_holdout_cross_kernel_using_training_means(H, T)
        if family is OPLS:
            fit_orthogonal_filter_using_training_fold_only()

        model_path = fit_one_maximal_component_path(
            training_fold=T,
            prefixes=components,
            fold_seed=seed + h
        )
        if head is LDA:
            fit_LDA_from_training_scores_or_equivalent_training_moments()
        prediction[H, ] = predict_all_prefixes(model_path, X_holdout)

    metric = evaluate_complete_out_of_fold_predictions(prediction)
    return select_within_requested_grid(metric, components)

NestedCV(...):
    for each outer fold o:
        selected = CV(data=outer_training_rows(o), ...)
        fit selected configuration on outer_training_rows(o)
        predict outer_holdout_rows(o)
    evaluate complete outer out-of-fold predictions
```

The critical invariant is that every statistic used to preprocess or fit fold
`h` equals the statistic computed directly from `T`. The full-data cache is only
an arithmetic device: each held-out contribution is removed before a training
mean, scale, cross-covariance, Gram matrix, OPLS filter, PLS model, or LDA head
is calculated.
