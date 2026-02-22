#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple

import numpy as np
import pandas as pd
import pickle
from scipy.signal import find_peaks


DEFAULT_WRIST_FS = {
    "BVP": 64,
    "EDA": 4,
    "TEMP": 4,
}


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Prepare WESAD windowed features for stress training")
    p.add_argument("--wesad-root", type=Path, required=True, help="Path to WESAD root directory")
    p.add_argument("--out-csv", type=Path, required=True, help="Output features CSV")
    p.add_argument("--window-seconds", type=int, default=30)
    p.add_argument("--step-seconds", type=int, default=5)
    return p.parse_args()


def _safe_stats(x: np.ndarray) -> Dict[str, float]:
    if x.size == 0:
        return {"avg": np.nan, "min": np.nan, "max": np.nan, "std": np.nan}
    return {
        "avg": float(np.mean(x)),
        "min": float(np.min(x)),
        "max": float(np.max(x)),
        "std": float(np.std(x)),
    }


def _slope(x: np.ndarray) -> float:
    if x.size < 2:
        return 0.0
    t = np.arange(x.size, dtype=np.float64)
    # robust small linear fit
    m = np.polyfit(t, x.astype(np.float64), deg=1)[0]
    return float(m)


def _hr_features_from_bvp(bvp: np.ndarray, fs: int) -> Dict[str, float]:
    if bvp.size < fs:
        return {
            "bpm_avg": np.nan,
            "bpm_min": np.nan,
            "bpm_max": np.nan,
            "bpm_std": np.nan,
            "hrv_rmssd": np.nan,
            "hrv_sdnn": np.nan,
        }

    # Normalize for peak detection stability
    centered = bvp - np.mean(bvp)
    scale = np.std(centered)
    if scale > 1e-9:
        centered = centered / scale

    distance = int(max(1, fs * 0.4))
    peaks, _ = find_peaks(centered, distance=distance, prominence=0.2)
    if peaks.size < 2:
        return {
            "bpm_avg": np.nan,
            "bpm_min": np.nan,
            "bpm_max": np.nan,
            "bpm_std": np.nan,
            "hrv_rmssd": np.nan,
            "hrv_sdnn": np.nan,
        }

    rr = np.diff(peaks) / fs  # seconds
    rr = rr[(rr > 0.3) & (rr < 1.8)]
    if rr.size < 2:
        return {
            "bpm_avg": np.nan,
            "bpm_min": np.nan,
            "bpm_max": np.nan,
            "bpm_std": np.nan,
            "hrv_rmssd": np.nan,
            "hrv_sdnn": np.nan,
        }

    bpm = 60.0 / rr
    rr_ms = rr * 1000.0

    diff_rr = np.diff(rr_ms)
    rmssd = np.sqrt(np.mean(diff_rr ** 2)) if diff_rr.size else np.nan
    sdnn = np.std(rr_ms) if rr_ms.size else np.nan

    return {
        "bpm_avg": float(np.mean(bpm)),
        "bpm_min": float(np.min(bpm)),
        "bpm_max": float(np.max(bpm)),
        "bpm_std": float(np.std(bpm)),
        "hrv_rmssd": float(rmssd),
        "hrv_sdnn": float(sdnn),
    }


def _majority_label(labels: np.ndarray) -> int:
    vals, counts = np.unique(labels.astype(int), return_counts=True)
    return int(vals[np.argmax(counts)])


def build_subject_rows(subject_dir: Path, window_seconds: int, step_seconds: int) -> List[Dict[str, float]]:
    sid = subject_dir.name
    pkl_path = subject_dir / f"{sid}.pkl"
    with pkl_path.open("rb") as f:
        data = pickle.load(f, encoding="latin1")

    wrist = data["signal"]["wrist"]
    label = np.asarray(data["label"]).reshape(-1)

    bvp = np.asarray(wrist["BVP"]).reshape(-1)
    eda = np.asarray(wrist["EDA"]).reshape(-1)
    temp = np.asarray(wrist["TEMP"]).reshape(-1)

    # Labels are at 700Hz in WESAD; resample labels to each wrist stream index by nearest mapping.
    label_fs = 700

    rows: List[Dict[str, float]] = []

    def label_for_window(start_idx: int, end_idx: int, sig_fs: int) -> int:
        t0 = start_idx / sig_fs
        t1 = end_idx / sig_fs
        l0 = int(max(0, np.floor(t0 * label_fs)))
        l1 = int(min(label.size, np.ceil(t1 * label_fs)))
        if l1 <= l0:
            return int(label[l0]) if l0 < label.size else -1
        return _majority_label(label[l0:l1])

    win_bvp = window_seconds * DEFAULT_WRIST_FS["BVP"]
    step_bvp = step_seconds * DEFAULT_WRIST_FS["BVP"]

    for start in range(0, bvp.size - win_bvp + 1, step_bvp):
        end = start + win_bvp

        bvp_win = bvp[start:end]

        # map to EDA/TEMP windows by time
        t0 = start / DEFAULT_WRIST_FS["BVP"]
        t1 = end / DEFAULT_WRIST_FS["BVP"]

        e0 = int(t0 * DEFAULT_WRIST_FS["EDA"])
        e1 = int(t1 * DEFAULT_WRIST_FS["EDA"])
        t0i = int(t0 * DEFAULT_WRIST_FS["TEMP"])
        t1i = int(t1 * DEFAULT_WRIST_FS["TEMP"])

        eda_win = eda[e0:e1]
        temp_win = temp[t0i:t1i]

        raw_label = label_for_window(start, end, DEFAULT_WRIST_FS["BVP"])
        if raw_label not in (1, 2):
            continue

        target = 0 if raw_label == 1 else 1

        hr = _hr_features_from_bvp(bvp_win, DEFAULT_WRIST_FS["BVP"])
        eda_stats = _safe_stats(eda_win)
        temp_stats = _safe_stats(temp_win)

        row = {
            "subject": sid,
            "window_start_s": float(t0),
            "window_end_s": float(t1),
            "label": target,
            **hr,
            "gsr_avg": eda_stats["avg"],
            "gsr_min": eda_stats["min"],
            "gsr_max": eda_stats["max"],
            "gsr_std": eda_stats["std"],
            "gsr_slope": _slope(eda_win),
            "temp_avg": temp_stats["avg"],
            "temp_min": temp_stats["min"],
            "temp_max": temp_stats["max"],
            "temp_std": temp_stats["std"],
            "temp_slope": _slope(temp_win),
        }

        rows.append(row)

    return rows


def main() -> None:
    args = parse_args()

    subject_dirs = sorted([p for p in args.wesad_root.iterdir() if p.is_dir() and p.name.startswith("S")])
    if not subject_dirs:
        raise SystemExit(f"No subject folders found in {args.wesad_root}")

    all_rows: List[Dict[str, float]] = []
    for sdir in subject_dirs:
        rows = build_subject_rows(sdir, args.window_seconds, args.step_seconds)
        all_rows.extend(rows)

    if not all_rows:
        raise SystemExit("No rows built. Check dataset path and label mapping.")

    df = pd.DataFrame(all_rows)
    df = df.replace([np.inf, -np.inf], np.nan)
    df = df.dropna()

    args.out_csv.parent.mkdir(parents=True, exist_ok=True)
    df.to_csv(args.out_csv, index=False)

    summary = {
        "rows": int(df.shape[0]),
        "columns": int(df.shape[1]),
        "subjects": sorted(df["subject"].unique().tolist()),
        "label_counts": df["label"].value_counts().to_dict(),
    }
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
