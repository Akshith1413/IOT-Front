"""
export_tflite.py — Export trained ECG model to float32 TFLite + C header

Pipeline:  PyTorch (.pth) → ONNX → TFLite (float32) → model_data.h

Usage:
    python export_tflite.py

Prerequisites:
    pip install torch onnx onnx-tf tensorflow

Outputs:
    ecg_model_float32.tflite   — TFLite model file
    model_data.h               — C byte array for Arduino firmware
"""

import os
import numpy as np
import torch
from model import ECGClassifier
from preprocessing import Config


# ══════════════════════════════════════════════════════════════════════════════
#  Step 1:  PyTorch → ONNX
# ══════════════════════════════════════════════════════════════════════════════
def export_to_onnx(pth_path: str = "best_ecg_model.pth",
                   onnx_path: str = "ecg_model.onnx"):
    model = ECGClassifier(num_classes=5)
    model.load_state_dict(torch.load(pth_path, map_location="cpu", weights_only=True))
    model.eval()

    # Dummy input: [batch=1, channels=1, seq_len=256]
    dummy = torch.randn(1, 1, Config.WINDOW_SIZE)

    torch.onnx.export(
        model,
        dummy,
        onnx_path,
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
        opset_version=13,
    )
    print(f"[1/4]  ONNX exported → {onnx_path}")
    return onnx_path


# ══════════════════════════════════════════════════════════════════════════════
#  Step 2:  ONNX → TensorFlow SavedModel
# ══════════════════════════════════════════════════════════════════════════════
def onnx_to_saved_model(onnx_path: str = "ecg_model.onnx",
                        saved_model_dir: str = "ecg_saved_model"):
    from onnx_tf.backend import prepare
    import onnx

    onnx_model = onnx.load(onnx_path)
    tf_rep = prepare(onnx_model)
    tf_rep.export_graph(saved_model_dir)
    print(f"[2/4]  TF SavedModel → {saved_model_dir}/")
    return saved_model_dir


# ══════════════════════════════════════════════════════════════════════════════
#  Step 3:  TF SavedModel → TFLite (float32)
# ══════════════════════════════════════════════════════════════════════════════
def saved_model_to_tflite(saved_model_dir: str = "ecg_saved_model",
                          tflite_path: str = "ecg_model_float32.tflite"):
    import tensorflow as tf

    converter = tf.lite.TFLiteConverter.from_saved_model(saved_model_dir)

    # ── Full float32 precision (no quantisation) ─────────────────────────────
    converter.target_spec.supported_types = [tf.float32]
    converter.optimizations = []                    # no optimisations = full float32

    tflite_model = converter.convert()

    with open(tflite_path, "wb") as f:
        f.write(tflite_model)

    size_kb = os.path.getsize(tflite_path) / 1024
    print(f"[3/4]  TFLite (float32) → {tflite_path}  ({size_kb:.1f} KB)")
    return tflite_path


# ══════════════════════════════════════════════════════════════════════════════
#  Step 4:  TFLite → C header (model_data.h)
# ══════════════════════════════════════════════════════════════════════════════
def tflite_to_c_header(tflite_path: str = "ecg_model_float32.tflite",
                       header_path: str = "model_data.h"):
    with open(tflite_path, "rb") as f:
        data = f.read()

    # Build the variable name from the file stem, replacing dots/hyphens
    var_name = os.path.splitext(os.path.basename(tflite_path))[0].replace("-", "_").replace(".", "_")
    var_name += "_tflite"  # e.g.  ecg_model_float32_tflite

    lines = [
        f"// Auto-generated from {os.path.basename(tflite_path)}",
        f"// Model size: {len(data)} bytes",
        f"// Input shape:  [1, 1, {Config.WINDOW_SIZE}]",
        f"// Output shape: [1, 5]",
        "",
        "#ifndef MODEL_DATA_H",
        "#define MODEL_DATA_H",
        "",
        f"alignas(16) const unsigned char {var_name}[] = {{",
    ]

    # Hex dump — 12 bytes per line
    for i in range(0, len(data), 12):
        chunk = data[i : i + 12]
        hex_vals = ", ".join(f"0x{b:02x}" for b in chunk)
        lines.append(f"  {hex_vals},")

    lines.append("};")
    lines.append(f"const unsigned int {var_name}_len = {len(data)};")
    lines.append("")
    lines.append("#endif  // MODEL_DATA_H")
    lines.append("")

    with open(header_path, "w") as f:
        f.write("\n".join(lines))

    print(f"[4/4]  C header → {header_path}  (array: {var_name})")
    return header_path


# ══════════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════════
if __name__ == "__main__":
    print("=" * 60)
    print("  ECG Model Export:  PyTorch → ONNX → TFLite (float32)")
    print("=" * 60)
    print()

    onnx_path       = export_to_onnx()
    saved_model_dir = onnx_to_saved_model(onnx_path)
    tflite_path     = saved_model_to_tflite(saved_model_dir)
    header_path     = tflite_to_c_header(tflite_path)

    print()
    print("=" * 60)
    print("  Done!  Copy these files to the firmware folder:")
    print(f"    {tflite_path}")
    print(f"    {header_path}")
    print("=" * 60)
