const fetch = require('node-fetch'); // You might need to install node-fetch: npm install node-fetch

// URL of the local emulator endpoint
// precise URL depends on your region and project ID, but usually:
const ENDPOINT_URL = "http://127.0.0.1:5001/iot-front-28748/us-central1/submitEcgData";

async function testEndpoint() {
    const data = [];
    const now = new Date();

    // Generate 10 sample points
    for (let i = 0; i < 10; i++) {
        data.push({
            timestamp: new Date(now.getTime() + i * 4).toISOString(), // 4ms increments (250Hz)
            ecg_value: 0.5 + Math.sin(i * 0.1) * 0.5,
            status: "normal"
        });
    }

    try {
        console.log("Sending data to:", ENDPOINT_URL);
        const response = await fetch(ENDPOINT_URL, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(data)
        });

        if (response.ok) {
            const json = await response.json();
            console.log("Success:", json);
        } else {
            const text = await response.text();
            console.error("Error:", response.status, text);
        }
    } catch (error) {
        console.error("Request failed. Make sure the Firebase Emulator is running.");
        console.error("Run: firebase emulators:start --only functions");
        console.error(error);
    }
}

testEndpoint();
