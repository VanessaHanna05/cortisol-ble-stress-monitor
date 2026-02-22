#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import List

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

LOCAL_REQUIRED = ["time_iso", "ts", "bpm_avg", "gsr_avg", "temp_avg", "label"]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Merge local sessions + WESAD features and train model")
    p.add_argument("--wesad-features", type=Path, required=True, help="Path to WESAD features CSV")
    p.add_argument("--local-dir", type=Path, required=True, help="Folder with local session CSVs")
    p.add_argument("--out-merged-csv", type=Path, default=Path("data/combined_features.csv"))
    p.add_argument("--out-dir", type=Path, default=Path("artifacts_combined"))
    p.add_argument("--test-size", type=float, default=0.25)
    p.add_argument("--random-state", type=int, default=42)
    p.add_argument("--local-weight", type=float, default=1.75, help="Sample weight multiplier for local rows")
    return p.parse_args()


def _rolling_slope(values: pd.Series, win: int = 8) -> pd.Series:
    out = np.zeros(len(values), dtype=np.float64)
    arr = values.to_numpy(dtype=np.float64)
    for i in range(len(arr)):
        lo = max(0, i - win + 1)
        y = arr[lo:i + 1]
        if len(y) < 2:
            out[i] = 0.0
            continue
        x = np.arange(len(y), dtype=np.float64)
        x_mean = x.mean()
        y_mean = y.mean()
        den = ((x - x_mean) ** 2).sum()
        if den < 1e-9:
            out[i] = 0.0
        else:
            out[i] = float(((x - x_mean) * (y - y_mean)).sum() / den)
    return pd.Series(out, index=values.index)


def _rmssd_from_bpm_series(bpm: pd.Series, win: int = 8) -> pd.Series:
    out = np.zeros(len(bpm), dtype=np.float64)
    arr = bpm.to_numpy(dtype=np.float64)
    for i in range(len(arr)):
        lo = max(0, i - win + 1)
        w = arr[lo:i + 1]
        w = w[np.isfinite(w) & (w > 1e-6)]
        if len(w) < 3:
            out[i] = 0.0
            continue
        rr = 60000.0 / w
        d = np.diff(rr)
        out[i] = float(np.sqrt(np.mean(d * d))) if len(d) else 0.0
    return pd.Series(out, index=bpm.index)


def _sdnn_from_bpm_series(bpm: pd.Series, win: int = 8) -> pd.Series:
    out = np.zeros(len(bpm), dtype=np.float64)
    arr = bpm.to_numpy(dtype=np.float64)
    for i in range(len(arr)):
        lo = max(0, i - win + 1)
        w = arr[lo:i + 1]
        w = w[np.isfinite(w) & (w > 1e-6)]
        if len(w) < 2:
            out[i] = 0.0
            continue
        rr = 60000.0 / w
        out[i] = float(np.std(rr))
    return pd.Series(out, index=bpm.index)


def _normalize_local_units(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    if out["gsr_avg"].median(skipna=True) > 50:
        out["gsr_avg"] = out["gsr_avg"] / 1000.0
    if out["temp_avg"].median(skipna=True) > 80:
        out["temp_avg"] = out["temp_avg"] / 10.0
    if out["temp_avg"].median(skipna=True) > 80:
        out["temp_avg"] = out["temp_avg"] / 10.0
    return out


def build_local_features(local_csv: Path) -> pd.DataFrame:
    df = pd.read_csv(local_csv)
    missing = [c for c in LOCAL_REQUIRED if c not in df.columns]
    if missing:
        raise ValueError(f"{local_csv.name} missing columns: {missing}")

    df = df.copy()
    df["time_iso"] = pd.to_datetime(df["time_iso"], errors="coerce")
    df = df.sort_values(["time_iso", "ts"], na_position="last").reset_index(drop=True)

    for c in ["bpm_avg", "gsr_avg", "temp_avg"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")

    df = _normalize_local_units(df)

    label_map = {
        "rest": 0,
        "recovery": 0,
        "unlabeled": 0,
        "stress_task": 1,
        "stress": 1,
    }
    df["label_bin"] = df["label"].astype(str).str.strip().str.lower().map(label_map)
    df = df.dropna(subset=["bpm_avg", "gsr_avg", "temp_avg", "label_bin"])

    win = 8
    out = pd.DataFrame(index=df.index)
    out["subject"] = f"LOCAL_{local_csv.stem}"
    out["label"] = df["label_bin"].astype(int)

    out["bpm_avg"] = df["bpm_avg"]
    out["bpm_min"] = df["bpm_avg"].rolling(win, min_periods=1).min()
    out["bpm_max"] = df["bpm_avg"].rolling(win, min_periods=1).max()
    out["bpm_std"] = df["bpm_avg"].rolling(win, min_periods=2).std().fillna(0.0)
    out["hrv_rmssd"] = _rmssd_from_bpm_series(df["bpm_avg"], win=win)
    out["hrv_sdnn"] = _sdnn_from_bpm_series(df["bpm_avg"], win=win)

    out["gsr_avg"] = df["gsr_avg"]
    out["gsr_min"] = df["gsr_avg"].rolling(win, min_periods=1).min()
    out["gsr_max"] = df["gsr_avg"].rolling(win, min_periods=1).max()
    out["gsr_std"] = df["gsr_avg"].rolling(win, min_periods=2).std().fillna(0.0)
    out["gsr_slope"] = _rolling_slope(df["gsr_avg"], win=win)

    out["temp_avg"] = df["temp_avg"]
    out["temp_min"] = df["temp_avg"].rolling(win, min_periods=1).min()
    out["temp_max"] = df["temp_avg"].rolling(win, min_periods=1).max()
    out["temp_std"] = df["temp_avg"].rolling(win, min_periods=2).std().fillna(0.0)
    out["temp_slope"] = _rolling_slope(df["temp_avg"], win=win)

    out = out.replace([np.inf, -np.inf], np.nan).dropna()
    return out[["subject", "label", *FEATURE_COLUMNS]]


def train_combined(df: pd.DataFrame, out_dir: Path, test_size: float, random_state: int, local_weight: float) -> None:
    X = df[FEATURE_COLUMNS].to_numpy(dtype=np.float64)
    y = df["label"].to_numpy(dtype=np.int64)
    groups = df["subject"].astype(str).to_numpy()

    splitter = GroupShuffleSplit(n_splits=1, test_size=test_size, random_state=random_state)
    train_idx, test_idx = next(splitter.split(X, y, groups))

    X_train, X_test = X[train_idx], X[test_idx]
    y_train, y_test = y[train_idx], y[test_idx]
    g_train, g_test = groups[train_idx], groups[test_idx]

    sample_weight = np.ones(len(train_idx), dtype=np.float64)
    local_mask = np.array([s.startswith("LOCAL_") for s in g_train])
    sample_weight[local_mask] = local_weight

    pipe = Pipeline(
        steps=[
            ("scaler", StandardScaler()),
            ("clf", LogisticRegression(max_iter=3000, class_weight="balanced", random_state=random_state)),
        ]
    )

    pipe.fit(X_train, y_train, clf__sample_weight=sample_weight)

    prob = pipe.predict_proba(X_test)[:, 1]
    pred = (prob >= 0.5).astype(int)

    metrics = {
        "rows_total": int(df.shape[0]),
        "rows_train": int(len(train_idx)),
        "rows_test": int(len(test_idx)),
        "subjects_train": sorted(set(g_train.tolist())),
        "subjects_test": sorted(set(g_test.tolist())),
        "accuracy": float(accuracy_score(y_test, pred)),
        "f1": float(f1_score(y_test, pred)),
        "precision": float(precision_score(y_test, pred, zero_division=0)),
        "recall": float(recall_score(y_test, pred, zero_division=0)),
        "roc_auc": float(roc_auc_score(y_test, prob)),
        "confusion_matrix": confusion_matrix(y_test, pred).tolist(),
        "classification_report": classification_report(y_test, pred, zero_division=0, output_dict=True),
        "local_weight": local_weight,
    }

    out_dir.mkdir(parents=True, exist_ok=True)

    model_pkl = out_dir / "model_joblib.pkl"
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

    with (out_dir / "model_flutter.json").open("w") as f:
        json.dump(flutter_model, f, indent=2)

    with (out_dir / "metrics.json").open("w") as f:
        json.dump(metrics, f, indent=2)

    print(json.dumps({
        "model": str(model_pkl),
        "flutter_model": str(out_dir / "model_flutter.json"),
        "metrics": str(out_dir / "metrics.json"),
        "f1": metrics["f1"],
        "roc_auc": metrics["roc_auc"],
    }, indent=2))


def main() -> None:
    args = parse_args()

    wesad_df = pd.read_csv(args.wesad_features)
    needed = set(["subject", "label", *FEATURE_COLUMNS])
    miss = needed - set(wesad_df.columns)
    if miss:
        raise SystemExit(f"WESAD features missing columns: {sorted(miss)}")
    wesad_df = wesad_df[["subject", "label", *FEATURE_COLUMNS]].copy()

    local_files = sorted(args.local_dir.glob("*.csv"))
    if not local_files:
        raise SystemExit(f"No local CSV files in {args.local_dir}")

    local_frames: List[pd.DataFrame] = []
    for f in local_files:
        local_frames.append(build_local_features(f))

    local_df = pd.concat(local_frames, ignore_index=True)
    combined = pd.concat([wesad_df, local_df], ignore_index=True)
    combined = combined.replace([np.inf, -np.inf], np.nan).dropna(subset=FEATURE_COLUMNS + ["label", "subject"])

    args.out_merged_csv.parent.mkdir(parents=True, exist_ok=True)
    combined.to_csv(args.out_merged_csv, index=False)

    print(json.dumps({
        "wesad_rows": int(wesad_df.shape[0]),
        "local_rows": int(local_df.shape[0]),
        "combined_rows": int(combined.shape[0]),
        "local_subjects": sorted(local_df["subject"].unique().tolist()),
        "out_merged_csv": str(args.out_merged_csv),
    }, indent=2))

    train_combined(
        df=combined,
        out_dir=args.out_dir,
        test_size=args.test_size,
        random_state=args.random_state,
        local_weight=args.local_weight,
    )


if __name__ == "__main__":
    main()
