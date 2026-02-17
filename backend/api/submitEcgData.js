const admin = require('../lib/firebase');

module.exports = async (req, res) => {
    // CORS
    res.setHeader('Access-Control-Allow-Credentials', true);
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,OPTIONS,PATCH,DELETE,POST,PUT');
    res.setHeader(
        'Access-Control-Allow-Headers',
        'X-CSRF-Token, X-Requested-With, Accept, Accept-Version, Content-Length, Content-MD5, Content-Type, Date, X-Api-Version'
    );

    if (req.method === 'OPTIONS') {
        res.status(200).end();
        return;
    }

    if (req.method !== 'POST') {
        res.status(405).json({ error: "Method Not Allowed" });
        return;
    }

    try {
        if (!admin) {
            throw new Error("Firebase Admin not initialized. Check serviceAccountKey.json");
        }

        const db = admin.database();
        const data = req.body;

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

        if (!points[0].timestamp || points[0].ecg_value === undefined) {
            res.status(400).json({ error: "Invalid data format. Expected {timestamp, ecg_value, status}" });
            return;
        }

        // Transaction to maintain rolling window
        const transactionResult = await db.ref("ecg_latest").transaction((currentData) => {
            let currentArray = [];
            if (currentData) {
                if (Array.isArray(currentData)) {
                    currentArray = currentData;
                } else {
                    currentArray = Object.values(currentData);
                }
            }

            let newArray = currentArray.concat(points);

            // Keep only last 300
            if (newArray.length > 300) {
                newArray = newArray.slice(newArray.length - 300);
            }
            return newArray;
        });

        const latestData = transactionResult.snapshot.val();

        // Derived Metrics
        const derived = calculateMetrics(latestData || points);

        await db.ref("ecg_metrics").set({
            timestamp: new Date().toISOString(),
            bpm: derived.bpm,
            status: derived.status
        });

        res.status(200).json({
            success: true,
            stored_total: latestData ? latestData.length : 0,
            derived: derived
        });

    } catch (error) {
        console.error("Error processing ECG data:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};

function calculateMetrics(data) {
    if (!data || data.length < 10) return { bpm: 0, status: "insufficient_data" };

    const dataArray = Array.isArray(data) ? data : Object.values(data);

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
            if (peaks.length === 0 || (i - peaks[peaks.length - 1].index > 50)) {
                peaks.push({ index: i, time: dataArray[i].timestamp });
            }
        }
    }

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
