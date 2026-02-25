"""
train.py — Train the ECG Classifier on MIT-BIH data resampled to 128 Hz

Usage:
    python train.py

After training completes, run:
    python export_tflite.py

to produce the float32 TFLite model + C header for Arduino.
"""

from torch.utils.data import DataLoader, random_split
from model import ECGClassifier, train_model, test_model
from preprocessing import loading_and_segmenting, ECGDataset, balanced_loader


if __name__ == "__main__":
    # ── 1. Load & preprocess (360 Hz → 128 Hz resampling happens inside) ─────
    print("Loading and resampling MIT-BIH data (360 Hz → 128 Hz)...")
    segments, labels = loading_and_segmenting()
    print(f"  Total segments: {len(segments)}  |  Shape: {segments.shape}")

    full_dataset = ECGDataset(segments, labels)

    # ── 2. Split: 70 / 15 / 15 ───────────────────────────────────────────────
    train_size = int(0.70 * len(full_dataset))
    val_size   = int(0.15 * len(full_dataset))
    test_size  = len(full_dataset) - train_size - val_size

    train_ds, val_ds, test_ds = random_split(
        full_dataset, [train_size, val_size, test_size]
    )
    print(f"  Train: {train_size}  |  Val: {val_size}  |  Test: {test_size}")

    # ── 3. Data loaders (balanced sampler for training only) ──────────────────
    train_loader = balanced_loader(train_ds, batch_size=64)
    val_loader   = DataLoader(val_ds,  batch_size=64, shuffle=False)
    test_loader  = DataLoader(test_ds, batch_size=64, shuffle=False)

    # ── 4. Train ──────────────────────────────────────────────────────────────
    ecg_model = ECGClassifier(num_classes=5)
    print("\nStarting training (50 epochs, patience=7)...\n")
    trained_model = train_model(ecg_model, train_loader, val_loader, epochs=50, patience=7)

    # ── 5. Evaluate on test set ───────────────────────────────────────────────
    print("\n── Test Set Evaluation ──")
    preds, labels = test_model(trained_model, test_loader)

    print("\nDone!  Best model saved to:  best_ecg_model.pth")
    print("Next step:  python export_tflite.py")
