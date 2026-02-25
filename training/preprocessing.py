"""
preprocessing.py — ECG Data Loading, Resampling & Segmentation

Key fix: MIT-BIH data is recorded at 360 Hz, but the MAX30001 sensor on the
Arduino Nano 33 BLE runs at 128 Hz.  We resample each record to 128 Hz BEFORE
segmenting so the model learns temporal patterns at the same rate it will see
during real-time inference.

Window: 256 samples @ 128 Hz ≈ 2.0 seconds (comfortably covers one full PQRST).
Normalization: z-score per segment — (segment - mean) / (std + 1e-8).
"""

import numpy as np
import torch
from torch.utils.data import WeightedRandomSampler, Dataset, DataLoader
import wfdb
from scipy.signal import resample


# ══════════════════════════════════════════════════════════════════════════════
#  Configuration
# ══════════════════════════════════════════════════════════════════════════════
class Config:
    ORIGINAL_SAMPLE_RATE = 360   # MIT-BIH native rate
    TARGET_SAMPLE_RATE   = 128   # MAX30001 hardware rate on Arduino
    WINDOW_SIZE          = 256   # samples per segment (at TARGET rate)
    AAMI_CLASSES = ['N', 'S', 'V', 'F', 'Q']

    AAMI_MAP = {
        # Normal (N)
        'N': 'N', 'L': 'N', 'R': 'N', 'e': 'N', 'j': 'N',
        # Supraventricular Ectopic (S)
        'A': 'S', 'a': 'S', 'J': 'S', 'S': 'S',
        # Ventricular Ectopic (V)
        'V': 'V', 'E': 'V',
        # Fusion (F)
        'F': 'F',
        # Unknown / Unclassifiable (Q)
        '/': 'Q', 'f': 'Q', 'Q': 'Q',
    }


# ══════════════════════════════════════════════════════════════════════════════
#  Dataset wrapper
# ══════════════════════════════════════════════════════════════════════════════
class ECGDataset(Dataset):
    def __init__(self, segments, labels):
        self.segments = torch.tensor(segments, dtype=torch.float32).unsqueeze(1)  # (N, 1, 256)
        self.labels   = torch.tensor(labels, dtype=torch.long)

    def __len__(self):
        return len(self.labels)

    def __getitem__(self, idx):
        return self.segments[idx], self.labels[idx]


# ══════════════════════════════════════════════════════════════════════════════
#  Loading, resampling & segmentation
# ══════════════════════════════════════════════════════════════════════════════
def loading_and_segmenting(
    filepath: str = "./mit-bih-arrhythmia-database-1.0.0/",
    window_size: int = Config.WINDOW_SIZE
):
    """
    1. Reads each MIT-BIH record (360 Hz).
    2. Resamples the signal to 128 Hz.
    3. Rescales annotation sample indices to the new rate.
    4. Extracts a window of `window_size` samples centred on each R-peak.
    5. Z-score normalises every segment independently.

    Returns
    -------
    segments : np.ndarray, shape (N, window_size), dtype float32
    labels   : np.ndarray, shape (N,), dtype int64
    """
    segments = []
    labels   = []
    half     = window_size // 2
    ratio    = Config.TARGET_SAMPLE_RATE / Config.ORIGINAL_SAMPLE_RATE

    LABEL_TO_IDX = {
        sym: Config.AAMI_CLASSES.index(Config.AAMI_MAP[sym])
        for sym in Config.AAMI_MAP
    }

    with open(filepath + "RECORDS") as f:
        records = f.read().splitlines()

    for rec_name in records:
        # ── Read original 360 Hz record ──────────────────────────────────────
        record     = wfdb.rdrecord(filepath + rec_name)
        annotation = wfdb.rdann(filepath + rec_name, "atr")
        signal_360 = record.p_signal[:, 0]               # lead 0

        # ── Resample 360 Hz → 128 Hz ────────────────────────────────────────
        new_length   = int(len(signal_360) * ratio)
        signal_128   = resample(signal_360, new_length)   # scipy

        # ── Rescale R-peak indices to the 128 Hz timeline ────────────────────
        for i in range(len(annotation.sample)):
            sym = annotation.symbol[i]
            if sym not in Config.AAMI_MAP:
                continue

            r_peak_128 = int(round(annotation.sample[i] * ratio))

            if r_peak_128 < half or r_peak_128 + half > len(signal_128):
                continue   # skip if window exceeds signal boundaries

            segment = signal_128[r_peak_128 - half : r_peak_128 + half]

            # z-score normalisation (identical to firmware)
            segment = (segment - segment.mean()) / (segment.std() + 1e-8)

            segments.append(segment)
            labels.append(LABEL_TO_IDX[sym])

    return np.array(segments, dtype=np.float32), np.array(labels, dtype=np.int64)


# ══════════════════════════════════════════════════════════════════════════════
#  Balanced data loader (handles class imbalance via WeightedRandomSampler)
# ══════════════════════════════════════════════════════════════════════════════
def balanced_loader(dataset, batch_size: int = 32) -> DataLoader:
    if isinstance(dataset, torch.utils.data.Subset):
        labels = dataset.dataset.labels[dataset.indices].numpy()
    else:
        labels = dataset.labels.numpy()

    num_classes = len(Config.AAMI_CLASSES)
    class_counts = np.zeros(num_classes)
    for t in labels:
        class_counts[t] += 1
    class_counts = np.where(class_counts == 0, 1, class_counts)

    weight = 1.0 / class_counts
    samples_weight = torch.tensor(weight[labels])

    sampler = WeightedRandomSampler(
        samples_weight, num_samples=len(samples_weight), replacement=True
    )
    return DataLoader(dataset, batch_size=batch_size, sampler=sampler)
