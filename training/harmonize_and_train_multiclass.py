#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple

import joblib
import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.ensemble import RandomForestClassifier, HistGradientBoostingClassifier
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
)
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
    p = argparse.ArgumentParser(description="Harmonize WESAD + nurse dataset and train a 3-class stress model")
    p.add_argument("--wesad-features", type=Path, required=True, help="WESAD features CSV from wesad_prepare.py")
    p.add_argument("--nurse-csv", type=Path, required=True, help="Nurse CSV with EDAR/HRR/TEMPR columns")
    p.add_argument("--out-merged-csv", type=Path, default=Path("data/hybrid_features.csv"))
    p.add_argument("--out-dir", type=Path, default=Path("artifacts_hybrid"))
    p.add_argument("--test-size", type=float, default=0.25)
    p.add_argument("--random-state", type=int, default=42)
    p.add_argument("--nurse-group-size", type=int, default=300, help="Rows per pseudo-subject group for nurse split")
    p.add_argument("--nurse-weight", type=float, default=1.25, help="Sample weight multiplier for nurse rows")
    p.add_argument(
        "--optimize-for",
        choices=["accuracy", "f1_macro"],
        default="accuracy",
        help="Metric used to select best model family",
    )
    return p.parse_args()


def _safe_numeric(df: pd.DataFrame, cols: List[str]) -> pd.DataFrame:
    out = df.copy()
    for c in cols:
        out[c] = pd.to_numeric(out[c], errors="coerce")
    return out


def _linear_quantile_align(
    series: pd.Series,
    src_q: Tuple[float, float],
    tgt_q: Tuple[float, float],
    clip: Tuple[float, float],
) -> pd.Series:
    s0, s1 = src_q
    t0, t1 = tgt_q
    den = max(1e-9, s1 - s0)
    scaled = (series - s0) / den
    mapped = t0 + scaled * (t1 - t0)
    return mapped.clip(clip[0], clip[1])


def _rolling_slope(arr: np.ndarray, win: int = 8) -> np.ndarray:
    out = np.zeros(len(arr), dtype=np.float64)
    for i in range(len(arr)):
        lo = max(0, i - win + 1)
        y = arr[lo : i + 1]
        if len(y) < 2:
            out[i] = 0.0
            continue
        x = np.arange(len(y), dtype=np.float64)
        xm = x.mean()
        ym = y.mean()
        den = ((x - xm) ** 2).sum()
        if den < 1e-9:
            out[i] = 0.0
        else:
            out[i] = float(((x - xm) * (y - ym)).sum() / den)
    return out


def _rmssd_from_bpm(bpm: np.ndarray, win: int = 8) -> np.ndarray:
    out = np.zeros(len(bpm), dtype=np.float64)
    for i in range(len(bpm)):
        lo = max(0, i - win + 1)
        w = bpm[lo : i + 1]
        w = w[np.isfinite(w) & (w > 1e-6)]
        if len(w) < 3:
            out[i] = 0.0
            continue
        rr = 60000.0 / w
        d = np.diff(rr)
        out[i] = float(np.sqrt(np.mean(d * d))) if len(d) else 0.0
    return out


def _sdnn_from_bpm(bpm: np.ndarray, win: int = 8) -> np.ndarray:
    out = np.zeros(len(bpm), dtype=np.float64)
    for i in range(len(bpm)):
        lo = max(0, i - win + 1)
        w = bpm[lo : i + 1]
        w = w[np.isfinite(w) & (w > 1e-6)]
        if len(w) < 2:
            out[i] = 0.0
            continue
        rr = 60000.0 / w
        out[i] = float(np.std(rr))
    return out


def build_wesad_frame(wesad_features_csv: Path) -> pd.DataFrame:
    df = pd.read_csv(wesad_features_csv)
    required = set(["subject", "label", *FEATURE_COLUMNS])
    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f"WESAD features missing columns: {sorted(missing)}")

    out = df[["subject", "label", *FEATURE_COLUMNS]].copy()
    # WESAD binary labels: 0=non-stress, 1=stress -> map to 3-class {0,2}
    out["label"] = out["label"].map({0: 0, 1: 2})
    out["source"] = "wesad"
    return out


def build_nurse_frame(
    nurse_csv: Path, wesad_reference: pd.DataFrame, group_size: int
) -> Tuple[pd.DataFrame, Dict[str, Dict[str, Dict[str, float]]]]:
    raw = pd.read_csv(nurse_csv)
    lag_cols = [str(i) for i in range(30, 0, -1) if str(i) in raw.columns]
    required = [
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
        "Stress",
    ]
    miss = [c for c in required if c not in raw.columns]
    if miss:
        raise SystemExit(f"Nurse CSV missing required columns: {miss}")

    cols_to_numeric = required + lag_cols
    raw = _safe_numeric(raw, cols_to_numeric).dropna(subset=required)

    out = pd.DataFrame(index=raw.index)
    out["gsr_avg"] = raw["EDAR_Mean"]
    out["gsr_min"] = raw["EDAR_Min"]
    out["gsr_max"] = raw["EDAR_Max"]
    out["gsr_std"] = raw["EDAR_Std"]
    out["bpm_avg"] = raw["HRR_Mean"]
    out["bpm_min"] = raw["HRR_Min"]
    out["bpm_max"] = raw["HRR_Max"]
    out["bpm_std"] = raw["HRR_Std"]
    out["temp_avg"] = raw["TEMPR_Mean"]
    out["temp_min"] = raw["TEMPR_Min"]
    out["temp_max"] = raw["TEMPR_Max"]
    out["temp_std"] = raw["TEMPR_Std"]

    # EDA lag columns represent recent history. Use them to estimate slope robustly.
    if lag_cols:
        lag_matrix = raw[lag_cols].to_numpy(dtype=np.float64)
        x = np.arange(lag_matrix.shape[1], dtype=np.float64)
        xm = x.mean()
        den = ((x - xm) ** 2).sum()
        ym = lag_matrix.mean(axis=1)
        num = ((x - xm) * (lag_matrix - ym[:, None])).sum(axis=1)
        out["gsr_slope"] = np.where(den > 1e-9, num / den, 0.0)
    else:
        out["gsr_slope"] = _rolling_slope(out["gsr_avg"].to_numpy(dtype=np.float64), win=8)

    out["temp_slope"] = _rolling_slope(out["temp_avg"].to_numpy(dtype=np.float64), win=8)

    # HRV proxy features are absent in nurse file. Estimate from bpm trajectory.
    bpm_arr = out["bpm_avg"].to_numpy(dtype=np.float64)
    out["hrv_rmssd"] = _rmssd_from_bpm(bpm_arr, win=8)
    out["hrv_sdnn"] = _sdnn_from_bpm(bpm_arr, win=8)

    sanity: Dict[str, Dict[str, Dict[str, float]]] = {"before": {}, "after": {}, "wesad_ref": {}}
    # Scale nurse features to WESAD-like physiological ranges using quantile alignment.
    for key, clip in [
        ("bpm_avg", (35.0, 190.0)),
        ("bpm_min", (30.0, 190.0)),
        ("bpm_max", (35.0, 220.0)),
        ("bpm_std", (0.0, 80.0)),
        ("gsr_avg", (0.01, 5.0)),
        ("gsr_min", (0.01, 5.0)),
        ("gsr_max", (0.01, 8.0)),
        ("gsr_std", (0.0, 2.5)),
        ("temp_avg", (28.0, 40.0)),
        ("temp_min", (28.0, 40.0)),
        ("temp_max", (28.0, 40.0)),
        ("temp_std", (0.0, 3.0)),
        ("hrv_rmssd", (0.0, 600.0)),
        ("hrv_sdnn", (0.0, 500.0)),
    ]:
        src = out[key].astype(float)
        ref = wesad_reference[key].astype(float)
        src_q = (float(np.nanpercentile(src, 5)), float(np.nanpercentile(src, 95)))
        ref_q = (float(np.nanpercentile(ref, 5)), float(np.nanpercentile(ref, 95)))
        sanity["before"][key] = {
            "p05": src_q[0],
            "p95": src_q[1],
            "median": float(np.nanmedian(src)),
        }
        sanity["wesad_ref"][key] = {
            "p05": ref_q[0],
            "p95": ref_q[1],
            "median": float(np.nanmedian(ref)),
        }
        out[key] = _linear_quantile_align(src, src_q, ref_q, clip)
        mapped = out[key].astype(float)
        sanity["after"][key] = {
            "p05": float(np.nanpercentile(mapped, 5)),
            "p95": float(np.nanpercentile(mapped, 95)),
            "median": float(np.nanmedian(mapped)),
        }

    # Label mapping from nurse dataset is already 0/1/2.
    out["label"] = raw["Stress"].round().astype(int).clip(0, 2)

    # Build pseudo-subjects for grouped split.
    block = np.arange(len(out)) // max(1, group_size)
    out["subject"] = [f"NURSE_{int(i):03d}" for i in block]
    out["source"] = "nurse"

    return out[["subject", "label", *FEATURE_COLUMNS, "source"]], sanity


def train_multiclass(
    df: pd.DataFrame,
    out_dir: Path,
    test_size: float,
    random_state: int,
    nurse_weight: float,
    optimize_for: str,
) -> None:
    df = df.replace([np.inf, -np.inf], np.nan).dropna(subset=["subject", "label", *FEATURE_COLUMNS])

    X = df[FEATURE_COLUMNS].to_numpy(dtype=np.float64)
    y = df["label"].to_numpy(dtype=np.int64)
    g = df["subject"].astype(str).to_numpy()
    src = df["source"].astype(str).to_numpy()

    splitter = GroupShuffleSplit(n_splits=1, test_size=test_size, random_state=random_state)
    tr_idx, te_idx = next(splitter.split(X, y, g))

    X_train, X_test = X[tr_idx], X[te_idx]
    y_train, y_test = y[tr_idx], y[te_idx]
    g_train, g_test = g[tr_idx], g[te_idx]
    src_train, src_test = src[tr_idx], src[te_idx]

    w = np.ones(len(tr_idx), dtype=np.float64)
    w[src_train == "nurse"] = float(nurse_weight)

    class_counts = np.bincount(y_train, minlength=3)
    class_balance = {i: (len(y_train) / (3.0 * max(1, int(c)))) for i, c in enumerate(class_counts)}
    for cls, mul in class_balance.items():
        w[y_train == cls] *= mul

    candidates = {
        "logistic_regression": Pipeline(
            steps=[
                ("scaler", StandardScaler()),
                (
                    "clf",
                    LogisticRegression(
                        max_iter=8000,
                        class_weight="balanced",
                        random_state=random_state,
                    ),
                ),
            ]
        ),
        "random_forest": RandomForestClassifier(
            n_estimators=600,
            max_depth=18,
            min_samples_leaf=2,
            class_weight="balanced_subsample",
            random_state=random_state,
            n_jobs=-1,
        ),
        "hist_gradient_boosting": HistGradientBoostingClassifier(
            max_iter=350,
            learning_rate=0.05,
            max_depth=8,
            random_state=random_state,
        ),
    }

    leaderboard = []
    trained_models = {}
    for name, model in candidates.items():
        if isinstance(model, Pipeline):
            model.fit(X_train, y_train, clf__sample_weight=w)
        else:
            model.fit(X_train, y_train, sample_weight=w)
        pred_i = model.predict(X_test)
        acc_i = float(accuracy_score(y_test, pred_i))
        f1m_i = float(f1_score(y_test, pred_i, average="macro", zero_division=0))
        leaderboard.append({"model": name, "accuracy": acc_i, "f1_macro": f1m_i})
        trained_models[name] = model

    if optimize_for == "accuracy":
        best_entry = max(leaderboard, key=lambda x: x["accuracy"])
    else:
        best_entry = max(leaderboard, key=lambda x: x["f1_macro"])

    best_name = best_entry["model"]
    best_model = trained_models[best_name]
    pred = best_model.predict(X_test)
    classes = sorted(np.unique(np.concatenate([y_train, y_test])).tolist())

    X_train_z = StandardScaler().fit_transform(X_train)
    z_abs = np.abs(X_train_z)
    metrics = {
        "rows_total": int(df.shape[0]),
        "rows_train": int(len(tr_idx)),
        "rows_test": int(len(te_idx)),
        "sources_total": df["source"].value_counts().to_dict(),
        "sources_train": pd.Series(src_train).value_counts().to_dict(),
        "sources_test": pd.Series(src_test).value_counts().to_dict(),
        "subjects_train": sorted(set(g_train.tolist())),
        "subjects_test": sorted(set(g_test.tolist())),
        "model_selected": best_name,
        "optimize_for": optimize_for,
        "leaderboard": sorted(
            leaderboard,
            key=lambda x: x["accuracy"] if optimize_for == "accuracy" else x["f1_macro"],
            reverse=True,
        ),
        "classes": classes,
        "accuracy": float(accuracy_score(y_test, pred)),
        "f1_macro": float(f1_score(y_test, pred, average="macro", zero_division=0)),
        "f1_weighted": float(f1_score(y_test, pred, average="weighted", zero_division=0)),
        "confusion_matrix": confusion_matrix(y_test, pred, labels=classes).tolist(),
        "classification_report": classification_report(
            y_test, pred, labels=classes, zero_division=0, output_dict=True
        ),
        "nurse_weight": nurse_weight,
        "zscore_outlier_fraction_abs_gt5_train": float((z_abs > 5.0).mean()),
    }

    args_out = out_dir
    args_out.mkdir(parents=True, exist_ok=True)
    model_pkl = args_out / "model_joblib.pkl"
    joblib.dump(best_model, model_pkl)

    # Always export a Flutter-friendly multinomial logistic fallback, since tree models are not yet implemented in app.
    fallback = candidates["logistic_regression"]
    if best_name == "logistic_regression":
        fallback = best_model
    else:
        fallback.fit(X_train, y_train, clf__sample_weight=w)

    scaler = fallback.named_steps["scaler"]
    clf = fallback.named_steps["clf"]
    flutter_model = {
        "type": "logistic_regression_multiclass",
        "classes": [int(c) for c in clf.classes_.tolist()],
        "features": FEATURE_COLUMNS,
        "scaler_mean": scaler.mean_.tolist(),
        "scaler_scale": scaler.scale_.tolist(),
        "coef": clf.coef_.tolist(),
        "intercept": clf.intercept_.tolist(),
        "note": "Fallback logistic model for Flutter runtime. Best offline model may differ; see metrics.model_selected.",
    }

    with (args_out / "model_flutter_multiclass.json").open("w") as f:
        json.dump(flutter_model, f, indent=2)
    with (args_out / "metrics.json").open("w") as f:
        json.dump(metrics, f, indent=2)

    print(
        json.dumps(
            {
                "model": str(model_pkl),
                "flutter_model": str(args_out / "model_flutter_multiclass.json"),
                "metrics": str(args_out / "metrics.json"),
                "f1_macro": metrics["f1_macro"],
                "accuracy": metrics["accuracy"],
                "model_selected": best_name,
            },
            indent=2,
        )
    )


def main() -> None:
    args = parse_args()
    wesad = build_wesad_frame(args.wesad_features)
    nurse, nurse_sanity = build_nurse_frame(args.nurse_csv, wesad_reference=wesad, group_size=args.nurse_group_size)
    combined = pd.concat([wesad, nurse], ignore_index=True)
    combined = combined.replace([np.inf, -np.inf], np.nan).dropna(subset=["subject", "label", *FEATURE_COLUMNS])

    args.out_merged_csv.parent.mkdir(parents=True, exist_ok=True)
    combined.to_csv(args.out_merged_csv, index=False)

    print(
        json.dumps(
            {
                "wesad_rows": int(wesad.shape[0]),
                "nurse_rows": int(nurse.shape[0]),
                "combined_rows": int(combined.shape[0]),
                "label_counts": combined["label"].value_counts().sort_index().to_dict(),
                "out_merged_csv": str(args.out_merged_csv),
            },
            indent=2,
        )
    )

    sanity = {
        "nurse_alignment": nurse_sanity,
        "combined_source_counts": combined["source"].value_counts().to_dict(),
        "combined_label_counts": combined["label"].value_counts().sort_index().to_dict(),
    }
    args.out_dir.mkdir(parents=True, exist_ok=True)
    with (args.out_dir / "sanity_checks.json").open("w") as f:
        json.dump(sanity, f, indent=2)

    train_multiclass(
        df=combined,
        out_dir=args.out_dir,
        test_size=args.test_size,
        random_state=args.random_state,
        nurse_weight=args.nurse_weight,
        optimize_for=args.optimize_for,
    )


if __name__ == "__main__":
    main()
