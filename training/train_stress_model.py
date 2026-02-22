#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score, precision_score, recall_score, roc_auc_score
from sklearn.model_selection import GroupShuffleSplit
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler


FEATURE_COLUMNS = [
    "bpm_avg",
    "bpm_min",
    "bpm_max",
    "bpm_std",
    "hrv_rmssd",
    "hrv_sdnn",
    "gsr_avg",
    "gsr_min",
    "gsr_max",
    "gsr_std",
    "gsr_slope",
    "temp_avg",
    "temp_min",
    "temp_max",
    "temp_std",
    "temp_slope",
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Train stress model from features CSV")
    p.add_argument("--features-csv", type=Path, required=True)
    p.add_argument("--out-dir", type=Path, required=True)
    p.add_argument("--test-size", type=float, default=0.25)
    p.add_argument("--random-state", type=int, default=42)
    return p.parse_args()


def main() -> None:
    args = parse_args()

    df = pd.read_csv(args.features_csv)
    needed = set(FEATURE_COLUMNS + ["label", "subject"])
    missing = needed - set(df.columns)
    if missing:
        raise SystemExit(f"Missing columns: {sorted(missing)}")

    df = df.replace([np.inf, -np.inf], np.nan).dropna(subset=FEATURE_COLUMNS + ["label", "subject"])

    X = df[FEATURE_COLUMNS].to_numpy(dtype=np.float64)
    y = df["label"].to_numpy(dtype=np.int64)
    groups = df["subject"].astype(str).to_numpy()

    splitter = GroupShuffleSplit(n_splits=1, test_size=args.test_size, random_state=args.random_state)
    train_idx, test_idx = next(splitter.split(X, y, groups))

    X_train, X_test = X[train_idx], X[test_idx]
    y_train, y_test = y[train_idx], y[test_idx]

    pipe = Pipeline(
        steps=[
            ("scaler", StandardScaler()),
            (
                "clf",
                LogisticRegression(
                    max_iter=2000,
                    class_weight="balanced",
                    random_state=args.random_state,
                ),
            ),
        ]
    )

    pipe.fit(X_train, y_train)

    prob = pipe.predict_proba(X_test)[:, 1]
    pred = (prob >= 0.5).astype(int)

    metrics = {
        "rows_total": int(df.shape[0]),
        "rows_train": int(X_train.shape[0]),
        "rows_test": int(X_test.shape[0]),
        "subjects_train": sorted(set(groups[train_idx].tolist())),
        "subjects_test": sorted(set(groups[test_idx].tolist())),
        "accuracy": float(accuracy_score(y_test, pred)),
        "f1": float(f1_score(y_test, pred)),
        "precision": float(precision_score(y_test, pred, zero_division=0)),
        "recall": float(recall_score(y_test, pred, zero_division=0)),
        "roc_auc": float(roc_auc_score(y_test, prob)),
        "confusion_matrix": confusion_matrix(y_test, pred).tolist(),
        "classification_report": classification_report(y_test, pred, zero_division=0, output_dict=True),
    }

    args.out_dir.mkdir(parents=True, exist_ok=True)

    model_pkl = args.out_dir / "model_joblib.pkl"
    joblib.dump(pipe, model_pkl)

    scaler = pipe.named_steps["scaler"]
    clf = pipe.named_steps["clf"]

    flutter_model = {
        "type": "logistic_regression_binary",
        "features": FEATURE_COLUMNS,
        "scaler_mean": scaler.mean_.tolist(),
        "scaler_scale": scaler.scale_.tolist(),
        "coef": clf.coef_[0].tolist(),
        "intercept": float(clf.intercept_[0]),
        "threshold": 0.5,
    }

    with (args.out_dir / "model_flutter.json").open("w") as f:
        json.dump(flutter_model, f, indent=2)

    with (args.out_dir / "metrics.json").open("w") as f:
        json.dump(metrics, f, indent=2)

    print(json.dumps({
        "model": str(model_pkl),
        "flutter_model": str(args.out_dir / "model_flutter.json"),
        "metrics": str(args.out_dir / "metrics.json"),
        "f1": metrics["f1"],
        "roc_auc": metrics["roc_auc"],
    }, indent=2))


if __name__ == "__main__":
    main()
