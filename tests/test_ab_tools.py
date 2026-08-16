import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[1]


def load_script(relative: str) -> ModuleType:
    path = ROOT / relative
    spec = importlib.util.spec_from_file_location(path.stem.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def base_summary() -> dict[str, tuple[float, float]]:
    keys = (
        "mean",
        "p50",
        "p95",
        "p99",
        "clip_low",
        "clip_high",
        "gradient",
        "local_contrast",
        "spatial_noise",
        "temporal_noise",
        "chroma",
        "rg_all",
        "bg_all",
        "rg_mid",
        "bg_mid",
        "rg_high",
        "bg_high",
    )

    return dict.fromkeys(keys, (10.0, 10.0))


def test_ab_image_diff_routes_colour_and_noise_to_one_shared_gate() -> None:
    ab = load_script("glue/capture/ab-image-diff.py")
    summary = base_summary()
    summary["gradient"] = (10.0, 12.0)
    summary["chroma"] = (10.0, 11.0)
    summary["rg_mid"] = (1.0, 1.06)

    items = ab.suggested_work(summary, [], [])

    assert items[0][1] == "cfa/cnf/cm/cm2 shared gate"
    assert "gain-keyed demosaic, chroma and colour rows together" in items[0][2]
    assert all(item[1] != "cm/cm2 colour rows" for item in items)
    assert all(item[1] != "cfa/cnf gate validation, then denoise" for item in items)


def test_ab_image_diff_rejects_ambiguous_labels(
        tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    ab = load_script("glue/capture/ab-image-diff.py")
    vendor = tmp_path / "vendor.mp4"
    open_file = tmp_path / "open.mp4"
    vendor.write_bytes(b"")
    open_file.write_bytes(b"")

    monkeypatch.setattr(
        "sys.argv",
        [
            "ab-image-diff.py",
            str(vendor),
            str(open_file),
            "--vendor-label",
            "vendor:bad",
        ],
    )
    with pytest.raises(SystemExit, match="must not contain"):
        ab.main()

    monkeypatch.setattr(
        "sys.argv",
        [
            "ab-image-diff.py",
            str(vendor),
            str(open_file),
            "--vendor-label",
            "same",
            "--open-label",
            "same",
        ],
    )
    with pytest.raises(SystemExit, match="must differ"):
        ab.main()


def test_ab_sweep_summary_reports_shared_gate_residual() -> None:
    sweep = load_script("glue/capture/ab-sweep-summary.py")
    row = {
        "mean_delta": 0.5,
        "tone_score": 1.0,
        "colour_delta": 0.06,
        "chroma_rel": 0.01,
        "denoise_rel": 0.12,
        "local_rel": 0.02,
    }

    assert sweep.dominant_residual(row) == "cfa/cnf/cm/cm2 shared gate"


def test_ab_sweep_summary_routes_chroma_residual_to_shared_gate() -> None:
    sweep = load_script("glue/capture/ab-sweep-summary.py")
    row = {
        "mean_delta": 0.5,
        "tone_score": 1.0,
        "colour_delta": 0.01,
        "chroma_rel": 0.10,
        "denoise_rel": 0.02,
        "local_rel": 0.02,
    }

    assert sweep.dominant_residual(row) == "cfa/cnf/cm/cm2 shared gate"


def test_ab_sweep_summary_reads_forced_point_label(tmp_path: Path) -> None:
    sweep = load_script("glue/capture/ab-sweep-summary.py")
    report = tmp_path / "report.md"
    report.write_text(
        "\n".join(
            [
                "# Vendor versus open: image comparison",
                "",
                "- vendor: `vendor.mp4` 1920x1080 60.00 fps 30.0 s",
                "- open-g3-d4: `open.mp4` 1920x1080 60.00 fps 30.0 s",
                "",
                "| vendor luma | 16 | 32 | 64 | 96 | 128 | 160 | 192 | 224 | 240 |",
            ]
        )
        + "\n"
    )

    label, tone_values = sweep.read_report(report)

    assert label == "open-g3-d4"
    assert tone_values == [16.0, 32.0, 64.0, 96.0, 128.0, 160.0, 192.0, 224.0, 240.0]


def test_ab_sweep_summary_rejects_malformed_samples_csv(tmp_path: Path) -> None:
    sweep = load_script("glue/capture/ab-sweep-summary.py")
    samples = tmp_path / "samples.csv"
    samples.write_text("leg,mean,p50\nvendor,10,10\nopen,11,11\n")

    with pytest.raises(ValueError, match="missing required sample column"):
        sweep.read_samples(samples)


def test_ab_sweep_summary_rejects_malformed_tone_row(tmp_path: Path) -> None:
    sweep = load_script("glue/capture/ab-sweep-summary.py")
    report = tmp_path / "report.md"
    report.write_text(
        "| vendor luma | 16 | nope | 64 | 96 | 128 | 160 | 192 | 224 | 240 |\n"
    )

    with pytest.raises(ValueError, match="malformed tone-transfer row"):
        sweep.read_report(report)
