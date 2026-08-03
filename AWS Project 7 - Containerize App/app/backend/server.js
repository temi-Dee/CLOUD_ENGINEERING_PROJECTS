const express = require('express');
const app = express();
const PORT = process.env.PORT || 3000;

app.get('/health', (req, res) => {
  res.json({ status: 'healthy', service: 'backend' });
});

// Also expose health under /api/health so the frontend can reach it
// through the nginx /api/ proxy pass rule.
app.get('/api/health', (req, res) => {
  res.json({ status: 'healthy', service: 'backend' });
});

app.get('/api/data', (req, res) => {
  res.json({
    timestamp: new Date().toISOString(),
    region: process.env.AWS_REGION || 'unknown',
    requestId: req.headers['x-request-id'] || null
  });
});

app.listen(PORT, () => {
  console.log(`Backend running on port ${PORT}`);
});
