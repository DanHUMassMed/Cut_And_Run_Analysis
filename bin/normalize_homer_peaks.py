#!/usr/bin/env python3
"""Append width-normalized tag columns (tags_per_kb) to HOMER annotatePeaks output."""

from __future__ import annotations

import argparse
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Add width-normalized tag columns (tags_per_kb) to HOMER annotatePeaks.pl output."
    )
    parser.add_argument("input_file", type=Path, help="Input HOMER annotatePeaks.txt file")
    parser.add_argument("output_file", type=Path, help="Output file with tags_per_kb columns appended")
    return parser.parse_args()


def normalize_homer_table(input_path: Path, output_path: Path) -> None:
    standard_column_count = 19
    with input_path.open("r", encoding="utf-8") as infile, output_path.open("w", encoding="utf-8") as outfile:
        header_line = infile.readline()
        if not header_line:
            return
        headers = header_line.rstrip("\r\n").split("\t")
        tag_headers = headers[standard_column_count:]
        norm_headers = [f"{col}_per_kb" for col in tag_headers]
        outfile.write("\t".join(headers + norm_headers) + "\n")

        for line in infile:
            fields = line.rstrip("\r\n").split("\t")
            if len(fields) <= standard_column_count:
                outfile.write(line)
                continue
            try:
                start = int(fields[2])
                end = int(fields[3])
                width_kb = max(abs(end - start), 1) / 1000.0
            except ValueError:
                width_kb = 1.0

            norm_vals: list[str] = []
            for raw_val in fields[standard_column_count:]:
                try:
                    val = float(raw_val)
                    norm_vals.append(f"{val / width_kb:.4f}")
                except ValueError:
                    norm_vals.append("NA")
            outfile.write("\t".join(fields + norm_vals) + "\n")


def main() -> None:
    args = parse_args()
    normalize_homer_table(args.input_file, args.output_file)


if __name__ == "__main__":
    main()

