#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple

import joblib
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
)
from sklearn.model_selection import GridSearchCV, GroupShuffleSplit, train_test_split


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train nurse-only Random Forest with random and blocked evaluation")
    p.add_argument("--nurse-csv", type=Path, required=True, help="Path to combined_lagEDA style nurse CSV")
    p.add_argument("--out-dir", type=Path, default=Path("artifacts_nurse_rf"))
    p.add_argument("--test-size", type=float, default=0.20, help="Test split size")
    p.add_argument("--random-state", type=int, default=42)
    p.add_argument("--group-size", type=int, default=120, help="Rows per contiguous block for blocked split")
    p.add_argument("--cv-folds", type=int, default=5)
    p.add_argument("--n-jobs", type=int, default=1, help="Parallel workers for sklearn/joblib")
    p.add_argument("--quick-grid", action="store_true", help="Use a tiny grid for fast smoke runs")
    p.add_argument(
        "--select-model",
        choices=["random", "blocked"],
        default="blocked",
        help="Which trained model to export as model_joblib.pkl",
    )
    return p.parse_args()


def _feature_columns(df: pd.DataFrame) -> List[str]:
    lag_cols = [str(i) for i in range(30, 0, -1)]
    base_cols = [
        "EDAR_Mean",
        "EDAR_Min",
        "EDAR_Max",
        "EDAR_Std",
        "HRR_Mean",
        "HRR_Min",
        "HRR_Max",
        "HRR_Std",
        "TEMPR_Mean",
        "TEMPR_Min",
        "TEMPR_Max",
        "TEMPR_Std",
    ]
    cols = lag_cols + base_cols
    missing = [c for c in cols if c not in df.columns]
    if missing:
        raise SystemExit(f"Nurse CSV missing required feature columns: {missing}")
    return cols


def _build_xy(df: pd.DataFrame, feature_cols: List[str]) -> Tuple[pd.DataFrame, np.ndarray]:
    work = df.copy()
    if "Stress" not in work.columns:
        raise SystemExit("Nurse CSV must include Stress column")

    work["Stress"] = pd.to_numeric(work["Stress"], errors="coerce")
    for c in feature_cols:
        work[c] = pd.to_numeric(work[c], errors="coerce")

    work = work.replace([np.inf, -np.inf], np.nan).dropna(subset=feature_cols + ["Stress"])
    work["Stress"] = work["Stress"].round().astype(int).clip(0, 2)

    X = work[feature_cols].copy()
    y = work["Stress"].to_numpy(dtype=np.int64)
    return X, y


def _evaluate(y_true: np.ndarray, y_pred: np.ndarray) -> Dict[str, object]:
    labels = [0, 1, 2]
    return {
        "accuracy": float(accuracy_score(y_true, y_pred)),
        "f1_macro": float(f1_score(y_true, y_pred, average="macro", zero_division=0)),
        "f1_weighted": float(f1_score(y_true, y_pred, average="weighted", zero_division=0)),
        "precision_macro": float(precision_score(y_true, y_pred, average="macro", zero_division=0)),
        "recall_macro": float(recall_score(y_true, y_pred, average="macro", zero_division=0)),
        "confusion_matrix": confusion_matrix(y_true, y_pred, labels=labels).tolist(),
        "classification_report": classification_report(
            y_true, y_pred, labels=labels, zero_division=0, output_dict=True
        ),
    }


def _fit_grid(
    X_train: pd.DataFrame,
    y_train: np.ndarray,
    random_state: int,
    cv_folds: int,
    n_jobs: int,
    quick_grid: bool,
) -> GridSearchCV:
    rf = RandomForestClassifier(random_state=random_state, class_weight="balanced", n_jobs=n_jobs)
    if quick_grid:
        param_grid = {
            "n_estimators": [200],
            "max_depth": [15],
            "min_samples_leaf": [3],
            "max_features": ["sqrt"],
        }
    else:
        param_grid = {
            "n_estimators": [300, 500],
            "max_depth": [10, 15, 20],
            "min_samples_leaf": [3, 5, 7],
            "max_features": ["sqrt", "log2"],
        }
    grid = GridSearchCV(
        rf,
        param_grid=param_grid,
        cv=cv_folds,
        scoring="f1_weighted",
        n_jobs=n_jobs,
        verbose=0,
    )
    grid.fit(X_train, y_train)
    return grid


def main() -> None:
    args = parse_args()
    df = pd.read_csv(args.nurse_csv)
    feature_cols = _feature_columns(df)
    X, y = _build_xy(df, feature_cols=feature_cols)

    # 1) Random split benchmark + grid search
    X_train_random, X_test_random, y_train_random, y_test_random = train_test_split(
        X,
        y,
        test_size=args.test_size,
        random_state=args.random_state,
        stratify=y,
    )
    grid_random = _fit_grid(
        X_train=X_train_random,
        y_train=y_train_random,
        random_state=args.random_state,
        cv_folds=args.cv_folds,
        n_jobs=args.n_jobs,
        quick_grid=args.quick_grid,
    )
    rf_random = grid_random.best_estimator_
    pred_random = rf_random.predict(X_test_random)
    metrics_random = _evaluate(y_test_random, pred_random)

    # 2) Blocked split evaluation with same best hyperparameters
    groups = (np.arange(len(X)) // max(1, args.group_size)).astype(int)
    split = GroupShuffleSplit(n_splits=1, test_size=args.test_size, random_state=args.random_state)
    tr_idx, te_idx = next(split.split(X.to_numpy(), y, groups=groups))
    X_train_blocked, X_test_blocked = X.iloc[tr_idx], X.iloc[te_idx]
    y_train_blocked, y_test_blocked = y[tr_idx], y[te_idx]

    best_params = grid_random.best_params_
    rf_blocked = RandomForestClassifier(
        random_state=args.random_state,
        class_weight="balanced",
        n_jobs=args.n_jobs,
        **best_params,
    )
    rf_blocked.fit(X_train_blocked, y_train_blocked)
    pred_blocked = rf_blocked.predict(X_test_blocked)
    metrics_blocked = _evaluate(y_test_blocked, pred_blocked)

    if args.select_model == "random":
        chosen_model = rf_random
        chosen_name = "random_split_model"
    else:
        chosen_model = rf_blocked
        chosen_name = "blocked_split_model"

    args.out_dir.mkdir(parents=True, exist_ok=True)
    model_path = args.out_dir / "model_joblib.pkl"
    joblib.dump(chosen_model, model_path)
    feature_cols_path = args.out_dir / "feature_cols.joblib"
    joblib.dump(feature_cols, feature_cols_path)

    importances = pd.DataFrame(
        {
            "feature": feature_cols,
            "importance": chosen_model.feature_importances_.tolist(),
        }
    ).sort_values("importance", ascending=False)
    importances_path = args.out_dir / "feature_importance.csv"
    importances.to_csv(importances_path, index=False)

    metrics = {
        "rows_total": int(len(X)),
        "features_count": int(X.shape[1]),
        "label_counts": pd.Series(y).value_counts().sort_index().to_dict(),
        "best_params_random_grid": best_params,
        "cv_best_score_f1_weighted": float(grid_random.best_score_),
        "model_random_state": args.random_state,
        "test_size": args.test_size,
        "group_size": args.group_size,
        "random_split_metrics": metrics_random,
        "blocked_split_metrics": metrics_blocked,
        "selected_model": chosen_name,
        "selection_mode": args.select_model,
        "note": "Random split is benchmark-like, blocked split is realistic for sequential lag windows.",
    }
    metrics_path = args.out_dir / "metrics.json"
    with metrics_path.open("w") as f:
        json.dump(metrics, f, indent=2)

    print(
        json.dumps(
            {
                "model": str(model_path),
                "metrics": str(metrics_path),
                "feature_importance": str(importances_path),
                "feature_cols": str(feature_cols_path),
                "random_split_accuracy": metrics_random["accuracy"],
                "random_split_f1_macro": metrics_random["f1_macro"],
                "blocked_split_accuracy": metrics_blocked["accuracy"],
                "blocked_split_f1_macro": metrics_blocked["f1_macro"],
                "selected_model": chosen_name,
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
