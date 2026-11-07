"""Transparent, conservative CSV cleaning for a teaching demonstration."""
from __future__ import annotations
import io
import json
import pandas as pd

MAX_CSV_BYTES = 5 * 1024 * 1024


def clean_csv(payload: bytes) -> tuple[bytes, dict]:
    if not payload or len(payload) > MAX_CSV_BYTES:
        raise ValueError('CSV must be nonempty and at most 5 MiB')
    try:
        frame = pd.read_csv(io.BytesIO(payload), encoding='utf-8')
    except (UnicodeDecodeError, pd.errors.ParserError, pd.errors.EmptyDataError) as exc:
        raise ValueError('Expected a valid UTF-8 CSV file') from exc
    if frame.empty or frame.columns.empty:
        raise ValueError('CSV must contain at least one data row and column')
    if frame.shape[1] > 100:
        raise ValueError('CSV has too many columns (100 maximum)')
    if len(frame) > 50000:
        raise ValueError('CSV has too many rows (50000 maximum)')

    original_rows = len(frame)
    original_missing = int(frame.isna().sum().sum())
    original_duplicates = int(frame.duplicated().sum())
    raw_cells = max(1, int(frame.size))
    before_quality = max(0, round(100 * (1 - (original_missing + original_duplicates) / raw_cells), 1))

    frame = frame.drop_duplicates().copy()
    after_dedup = len(frame)
    handling: dict[str, str] = {}
    # Only infer numerics already parsed by pandas; do not force numeric identifiers.
    for name in frame.columns:
        if pd.api.types.is_numeric_dtype(frame[name]):
            valid = frame[name].dropna()
            median = valid.median() if not valid.empty else float("nan")
            fill = float(median) if pd.notna(median) else 0.0
            frame[name] = frame[name].fillna(fill)
            handling[str(name)] = 'median' if pd.notna(median) else 'zero (entire column missing)'
        else:
            mode = frame[name].mode(dropna=True)
            fill = str(mode.iloc[0]) if not mode.empty else 'Unknown'
            frame[name] = frame[name].fillna(fill)
            handling[str(name)] = 'mode' if not mode.empty else 'Unknown (entire column missing)'

    outliers: dict[str, int] = {}
    for name in frame.select_dtypes(include='number').columns:
        col = frame[name].dropna()
        if len(col) < 4:
            continue
        q1, q3 = col.quantile(.25), col.quantile(.75)
        span = q3 - q1
        # Report outliers; don't delete potentially meaningful observations.
        if span > 0:
            outliers[str(name)] = int(((col < q1 - 1.5 * span) | (col > q3 + 1.5 * span)).sum())

    # Protect exported CSVs when viewed in spreadsheet applications. This deliberately
    # changes formula-like text cells; consult the limitation in the quality report.
    escaped_formula_cells = 0
    for name in frame.select_dtypes(include="object").columns:
        def escape_formula(value):
            nonlocal escaped_formula_cells
            if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@")):
                escaped_formula_cells += 1
                return "'" + value
            return value
        frame[name] = frame[name].map(escape_formula)

    remaining_missing = int(frame.isna().sum().sum())
    after_quality = max(0, round(100 * (1 - remaining_missing / max(1, int(frame.size))), 1))
    report = {
        'original_rows': original_rows,
        'cleaned_rows': after_dedup,
        'columns': [str(c) for c in frame.columns],
        'duplicates_removed': original_duplicates,
        'missing_cells_before': original_missing,
        'missing_cells_after': remaining_missing,
        'quality_score_before': before_quality,
        'quality_score_after': after_quality,
        'missing_value_strategy': handling,
        'outliers_flagged_not_removed': outliers,
        'spreadsheet_formula_cells_escaped': escaped_formula_cells,
        'limitations': 'Basic tabular cleaning only. Does not handle leakage, label issues or domain-specific preprocessing. Formula-like text is prefixed with an apostrophe for safe spreadsheet export.',
    }
    return frame.to_csv(index=False).encode('utf-8'), report
