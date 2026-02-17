const admin = require('../lib/firebase');

module.exports = async (req, res) => {
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

    try {
        if (!admin) {
            throw new Error("Firebase Admin not initialized. Check serviceAccountKey.json");
        }

        const db = admin.database();
        const snapshot = await db.ref("ecg_latest").once("value");
        const data = snapshot.val();

        const results = data ? (Array.isArray(data) ? data : Object.values(data)) : [];

        res.status(200).json({
            success: true,
            count: results.length,
            data: results
        });
    } catch (error) {
        console.error("Error fetching ECG data:", error);
        res.status(500).json({ error: error.message || "Internal Server Error" });
    }
};
