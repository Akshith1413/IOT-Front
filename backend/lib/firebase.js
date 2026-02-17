const admin = require('firebase-admin');

// Prevent multiple initializations in serverless environment
if (!admin.apps.length) {
    try {
        // We will look for serviceAccountKey.json in the same directory or environment variables
        // For simplicity in this project, we are loading from a file.
        // In production, best practice is process.env.FIREBASE_SERVICE_ACCOUNT

        // Check if the file exists locally (for local dev) or if we are using env vars
        // User needs to place 'serviceAccountKey.json' in 'backend/' folder.

        // 1. Try Environment Variable (Best for Production/Vercel)
        if (process.env.FIREBASE_SERVICE_ACCOUNT) {
            const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
            admin.initializeApp({
                credential: admin.credential.cert(serviceAccount),
                databaseURL: "https://iot-front-28748-default-rtdb.firebaseio.com"
            });
        }
        // 2. Fallback to local file (Best for Local Dev)
        else {
            const serviceAccount = require('../serviceAccountKey.json');
            admin.initializeApp({
                credential: admin.credential.cert(serviceAccount),
                databaseURL: "https://iot-front-28748-default-rtdb.firebaseio.com"
            });
        }
    } catch (error) {
        console.error("Firebase admin initialization error", error);
        // Fallback or re-throw? 
        // If we fail here, the functions will fail.
        // We might be missing the key file.
    }
}

module.exports = admin;
