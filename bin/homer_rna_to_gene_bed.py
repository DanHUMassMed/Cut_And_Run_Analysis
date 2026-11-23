#!/usr/bin/env python3
"""Convert HOMER <genome>.rna annotation file into a deduplicated 6-column stranded gene BED."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class GeneInterval:
    chrom: str
    start: int
    end: int
    name: str
    strand: str

    @property
    def length(self) -> int:
        return self.end - self.start


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert HOMER <genome>.rna into a 6-column stranded BED for deepTools TSS/gene-body metaplots."
    )
    parser.add_argument("--homer-rna", type=Path, required=True, help="Path to HOMER <genome>.rna file")
    parser.add_argument("--chrom-sizes", type=Path, required=True, help="Path to chrom.sizes file")
    parser.add_argument("--output", type=Path, required=True, help="Output 6-column BED file path")
    parser.add_argument(
        "--include-chrm",
        action="store_true",
        help="Include mitochondrial chromosome (excluded by default)",
    )
    parser.add_argument(
        "--no-collapse-isoforms",
        action="store_true",
        help="Keep all unique transcript intervals instead of collapsing overlapping same-strand isoforms",
    )
    return parser.parse_args()


def load_chrom_sizes(chrom_sizes_path: Path, include_chrm: bool) -> dict[str, int]:
    chrom_sizes: dict[str, int] = {}
    with chrom_sizes_path.open("r", encoding="utf-8") as handle:
        for line in handle:
            parts = line.strip().split("\t")
            if len(parts) < 2:
                continue
            chrom = parts[0]
            if not include_chrm and chrom.lower() in {"chrm", "mt", "mtdna", "chrmt"}:
                continue
            try:
                chrom_sizes[chrom] = int(parts[1])
            except ValueError:
                continue
    return chrom_sizes


def parse_homer_rna(rna_path: Path, chrom_sizes: dict[str, int]) -> list[GeneInterval]:
    seen_coords: set[tuple[str, int, int, str]] = set()
    intervals: list[GeneInterval] = []
    with rna_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            parts = stripped.split("\t")
            if len(parts) < 5:
                continue
            name, chrom, start_raw, end_raw, strand_raw = parts[0], parts[1], parts[2], parts[3], parts[4]
            if chrom not in chrom_sizes:
                continue
            try:
                start = max(int(start_raw), 0)
                end = min(int(end_raw), chrom_sizes[chrom])
            except ValueError:
                continue
            if end <= start:
                continue
            if strand_raw in {"+", "0"}:
                strand = "+"
            elif strand_raw in {"-", "1"}:
                strand = "-"
            else:
                continue
            key = (chrom, start, end, strand)
            if key in seen_coords:
                continue
            seen_coords.add(key)
            intervals.append(GeneInterval(chrom=chrom, start=start, end=end, name=name, strand=strand))
    return intervals


def collapse_overlapping_isoforms(intervals: list[GeneInterval]) -> list[GeneInterval]:
    """Keep the longest transcript per overlapping same-strand locus to avoid isoform inflation."""
    by_chrom_strand: dict[tuple[str, str], list[GeneInterval]] = {}
    for iv in intervals:
        by_chrom_strand.setdefault((iv.chrom, iv.strand), []).append(iv)

    collapsed: list[GeneInterval] = []
    for key in sorted(by_chrom_strand.keys()):
        group = sorted(by_chrom_strand[key], key=lambda x: (x.start, -x.end))
        best = group[0]
        cluster_end = best.end
        for iv in group[1:]:
            if iv.start < cluster_end:
                cluster_end = max(cluster_end, iv.end)
                if iv.length > best.length:
                    best = iv
            else:
                collapsed.append(best)
                best = iv
                cluster_end = iv.end
        collapsed.append(best)

    collapsed.sort(key=lambda x: (x.chrom, x.start, x.end, x.strand))
    return collapsed


def write_bed6(intervals: list[GeneInterval], out_path: Path) -> None:
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as handle:
        for iv in intervals:
            handle.write(f"{iv.chrom}\t{iv.start}\t{iv.end}\t{iv.name}\t0\t{iv.strand}\n")


def main() -> None:
    args = parse_args()
    chrom_sizes = load_chrom_sizes(args.chrom_sizes, include_chrm=args.include_chrm)
    intervals = parse_homer_rna(args.homer_rna, chrom_sizes)
    if not args.no_collapse_isoforms and intervals:
        intervals = collapse_overlapping_isoforms(intervals)
    else:
        intervals.sort(key=lambda x: (x.chrom, x.start, x.end, x.strand))
    write_bed6(intervals, args.output)


if __name__ == "__main__":
    main()
