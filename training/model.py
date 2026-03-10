"""
model.py — Lightweight 1D CNN for ECG Arrhythmia Classification

Architecture:
  Conv1d(1→16, k=5) → BN → ReLU → MaxPool(2)     # 256 → 128
  Conv1d(16→32, k=5) → BN → ReLU → MaxPool(2)     # 128 → 64
  Conv1d(32→64, k=5) → BN → ReLU → MaxPool(2)     # 64  → 32
  AdaptiveAvgPool1d(1)                              # 32  → 1  (feature vec = 64)
  Linear(64, 32) → ReLU → Dropout(0.3)
  Linear(32, 5)                                    # raw logits

Input:  [Batch, 1, 256]
Output: [Batch, 5]  (logits — no softmax; CrossEntropyLoss handles it)
"""

import torch
import torch.nn as nn
import torch.nn.functional as F


class ECGClassifier(nn.Module):
    def __init__(self, num_classes: int = 5):
        super(ECGClassifier, self).__init__()

        # Conv Block 1
        self.conv1 = nn.Conv1d(in_channels=1, out_channels=16, kernel_size=5, padding=2)
        self.bn1   = nn.BatchNorm1d(16)

        # Conv Block 2
        self.conv2 = nn.Conv1d(16, 32, kernel_size=5, padding=2)
        self.bn2   = nn.BatchNorm1d(32)

        # Conv Block 3
        self.conv3 = nn.Conv1d(32, 64, kernel_size=5, padding=2)
        self.bn3   = nn.BatchNorm1d(64)

        self.pool    = nn.MaxPool1d(kernel_size=2)
        self.dropout = nn.Dropout(0.3)

        # Global Average Pooling
        self.global_pool = nn.AdaptiveAvgPool1d(1)

        # Fully Connected Layers
        self.fc1 = nn.Linear(64, 32)
        self.fc2 = nn.Linear(32, num_classes)

    def forward(self, x):
        # x: [B, 1, 256]
        x = self.pool(F.relu(self.bn1(self.conv1(x))))   # → [B, 16, 128]
        x = self.pool(F.relu(self.bn2(self.conv2(x))))   # → [B, 32, 64]
        x = self.pool(F.relu(self.bn3(self.conv3(x))))   # → [B, 64, 32]

        x = self.global_pool(x)    # → [B, 64, 1]
        x = x.squeeze(-1)          # → [B, 64]

        x = F.relu(self.fc1(x))
        x = self.dropout(x)
        x = self.fc2(x)            # → [B, 5]  (logits)
        return x


# ══════════════════════════════════════════════════════════════════════════════
#  Training loop
# ══════════════════════════════════════════════════════════════════════════════
def train_model(model, train_loader, val_loader, epochs=50, patience=7):
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model.to(device)

    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(model.parameters(), lr=0.001)

    best_val_loss      = float('inf')
    early_stop_counter = 0

    for epoch in range(epochs):
        # ── Training ─────────────────────────────────────────────────────────
        model.train()
        train_loss, correct = 0, 0
        for signals, labels in train_loader:
            signals, labels = signals.to(device), labels.to(device)

            optimizer.zero_grad()
            outputs = model(signals)
            loss    = criterion(outputs, labels)
            loss.backward()
            optimizer.step()

            train_loss += loss.item()
            _, predicted = outputs.max(1)
            correct += predicted.eq(labels).sum().item()

        # ── Validation ───────────────────────────────────────────────────────
        model.eval()
        val_loss, val_correct = 0, 0
        with torch.no_grad():
            for signals, labels in val_loader:
                signals, labels = signals.to(device), labels.to(device)
                outputs = model(signals)
                loss    = criterion(outputs, labels)
                val_loss += loss.item()
                _, predicted = outputs.max(1)
                val_correct += predicted.eq(labels).sum().item()

        avg_train_loss = train_loss / len(train_loader)
        avg_val_loss   = val_loss   / len(val_loader)
        val_acc        = 100.0 * val_correct / len(val_loader.dataset)

        print(
            f"Epoch {epoch + 1}: "
            f"Train Loss: {avg_train_loss:.4f} | "
            f"Val Loss: {avg_val_loss:.4f} | "
            f"Val Acc: {val_acc:.2f}%"
        )

        # ── Checkpointing & early stopping ───────────────────────────────────
        if avg_val_loss < best_val_loss:
            best_val_loss = avg_val_loss
            torch.save(model.state_dict(), "best_ecg_model.pth")
            early_stop_counter = 0
            print("  --> Model saved!")
        else:
            early_stop_counter += 1
            if early_stop_counter >= patience:
                print("Early stopping triggered.")
                break

    model.load_state_dict(torch.load("best_ecg_model.pth", weights_only=True))
    return model


# ══════════════════════════════════════════════════════════════════════════════
#  Testing
# ══════════════════════════════════════════════════════════════════════════════
def test_model(model, test_loader):
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model.to(device)
    model.eval()

    criterion = nn.CrossEntropyLoss()
    test_loss, correct, total = 0, 0, 0
    all_preds, all_labels = [], []

    with torch.no_grad():
        for signals, labels in test_loader:
            signals, labels = signals.to(device), labels.to(device)
            outputs = model(signals)
            loss    = criterion(outputs, labels)

            test_loss += loss.item()
            _, predicted = torch.max(outputs, 1)
            total   += labels.size(0)
            correct += (predicted == labels).sum().item()

            all_preds.extend(predicted.cpu().numpy())
            all_labels.extend(labels.cpu().numpy())

    avg_test_loss = test_loss / len(test_loader)
    test_acc      = 100.0 * correct / total

    print(f"Test Loss: {avg_test_loss:.4f}")
    print(f"Test Accuracy: {test_acc:.2f}%")

    return all_preds, all_labels
