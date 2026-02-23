#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Export nurse RF model to Flutter JSON")
    p.add_argument("--model-joblib", type=Path, required=True)
    p.add_argument("--feature-cols-joblib", type=Path, required=True)
    p.add_argument("--nurse-csv", type=Path, required=True)
    p.add_argument("--out-json", type=Path, required=True)
    return p.parse_args()


def main() -> None:
    args = parse_args()

    model = joblib.load(args.model_joblib)
    feature_cols = list(joblib.load(args.feature_cols_joblib))

    df = pd.read_csv(args.nurse_csv)
    work = df.copy()
    for c in feature_cols:
        work[c] = pd.to_numeric(work[c], errors="coerce")
    work = work.replace([np.inf, -np.inf], np.nan).dropna(subset=feature_cols)

    feat_min = work[feature_cols].min().to_dict()
    feat_max = work[feature_cols].max().to_dict()

    trees = []
    for est in model.estimators_:
        t = est.tree_
        trees.append(
            {
                "children_left": t.children_left.tolist(),
                "children_right": t.children_right.tolist(),
                "feature": t.feature.tolist(),
                "threshold": t.threshold.tolist(),
                "value": t.value.squeeze(axis=1).tolist(),
            }
        )

    payload = {
        "type": "random_forest_multiclass",
        "classes": [int(c) for c in model.classes_.tolist()],
        "features": feature_cols,
        "feature_min": {k: float(feat_min[k]) for k in feature_cols},
        "feature_max": {k: float(feat_max[k]) for k in feature_cols},
        "n_estimators": int(len(trees)),
        "trees": trees,
        "note": "Exported from nurse RandomForest model",
    }

    args.out_json.parent.mkdir(parents=True, exist_ok=True)
    with args.out_json.open("w") as f:
        json.dump(payload, f)

    print(
        json.dumps(
            {
                "out_json": str(args.out_json),
                "n_estimators": payload["n_estimators"],
                "features": len(feature_cols),
                "size_mb": round(args.out_json.stat().st_size / (1024 * 1024), 2),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
