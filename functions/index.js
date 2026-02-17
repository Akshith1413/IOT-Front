const functions = require("firebase-functions");
const admin = require("firebase-admin");

admin.initializeApp();

const db = admin.database();

/**
 * Cloud Function to handle incoming ECG data from IoT device.
 * It stores the data points and maintains a rolling window of the last 300 points.
 * It also calculates basic derived metrics like Heart Rate.
 */
exports.submitEcgData = functions.https.onRequest(async (req, res) => {
    // Enable CORS
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET, POST");

    if (req.method === "OPTIONS") {
        res.status(204).send("");
        return;
    }

    if (req.method !== "POST") {
        res.status(405).send("Method Not Allowed");
        return;
    }

    try {
        const data = req.body;

        // Validate input (check if single object or array)
        // We support batching for efficiency, or single point
        let points = [];
        if (Array.isArray(data)) {
            points = data;
        } else if (data && typeof data === 'object') {
            points = [data];
        }

        if (points.length === 0) {
            res.status(400).json({ error: "No data provided" });
            return;
        }

        // Basic validation of the first point
        if (!points[0].timestamp || points[0].ecg_value === undefined) {
            res.status(400).json({ error: "Invalid data format. Expected {timestamp, ecg_value, status}" });
            return;
        }

        // We only store the latest 300 points in 'ecg_latest' node.

        const transactionResult = await db.ref("ecg_latest").transaction((currentData) => {
            let currentArray = [];
            if (currentData) {
                // handle case where firebase returns object instead of array
                if (Array.isArray(currentData)) {
                    currentArray = currentData;
                } else {
                    currentArray = Object.values(currentData);
                }
            }

            let newArray = currentArray.concat(points); // Append new points

            // Keep only last 300
            if (newArray.length > 300) {
                newArray = newArray.slice(newArray.length - 300);
            }
            return newArray;
        });

        const latestData = transactionResult.snapshot.val();

        // 3. Derived Metrics Calculation
        const derived = calculateMetrics(latestData || points);

        // Store metrics
        await db.ref("ecg_metrics").set({
            timestamp: new Date().toISOString(),
            bpm: derived.bpm,
            status: derived.status,
            // peaks: derived.peaks // Optional: storing peaks for debugging
        });

        res.json({
            success: true,
            stored_total: latestData ? latestData.length : 0,
            derived: derived
        });

    } catch (error) {
        console.error("Error processing ECG data:", error);
        res.status(500).json({ error: "Internal Server Error" });
    }
});

/**
 * Cloud Function to retrieve the latest 300 ECG data points.
 * Usage: GET /getLatestEcg
 */
exports.getLatestEcg = functions.https.onRequest(async (req, res) => {
    // Enable CORS
    res.set("Access-Control-Allow-Origin", "*");
    res.set("Access-Control-Allow-Methods", "GET");

    if (req.method === "OPTIONS") {
        res.status(204).send("");
        return;
    }

    try {
        const snapshot = await db.ref("ecg_latest").once("value");
        const data = snapshot.val();

        // If data is null, return empty array
        const results = data ? (Array.isArray(data) ? data : Object.values(data)) : [];

        res.json({
            success: true,
            count: results.length,
            data: results
        });
    } catch (error) {
        console.error("Error fetching ECG data:", error);
        res.status(500).json({ error: "Internal Server Error" });
    }
});

function calculateMetrics(data) {
    if (!data || data.length < 10) return { bpm: 0, status: "insufficient_data" };

    // Convert to array if it's an object (Firebase quirk)
    const dataArray = Array.isArray(data) ? data : Object.values(data);

    // 1. Find peaks (R-waves)
    let maxVal = -Infinity;
    dataArray.forEach(d => {
        const val = parseFloat(d.ecg_value);
        if (val > maxVal) maxVal = val;
    });

    const threshold = maxVal * 0.7;
    let peaks = [];

    for (let i = 1; i < dataArray.length - 1; i++) {
        const prev = parseFloat(dataArray[i - 1].ecg_value);
        const curr = parseFloat(dataArray[i].ecg_value);
        const next = parseFloat(dataArray[i + 1].ecg_value);

        if (curr > threshold && curr > prev && curr > next) {
            // 50 samples refractory period
            if (peaks.length === 0 || (i - peaks[peaks.length - 1].index > 50)) {
                peaks.push({ index: i, time: dataArray[i].timestamp });
            }
        }
    }

    // 2. Calculate BPM
    let bpm = 0;
    if (peaks.length > 1) {
        try {
            const firstPeak = new Date(peaks[0].time).getTime();
            const lastPeak = new Date(peaks[peaks.length - 1].time).getTime();
            const durationMs = lastPeak - firstPeak;

            if (durationMs > 0) {
                const avgInterval = durationMs / (peaks.length - 1); // ms per beat
                bpm = Math.round(60000 / avgInterval);
            }
        } catch (e) {
            console.error("Error calculating BPM dates", e);
        }
    }

    return {
        bpm: bpm,
        status: bpm > 100 ? "tachycardia" : (bpm < 60 && bpm > 0 ? "bradycardia" : "normal")
    };
}
