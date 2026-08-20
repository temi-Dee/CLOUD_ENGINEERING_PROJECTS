const { S3Client, HeadObjectCommand, PutObjectCommand } = require('@aws-sdk/client-s3');
const s3 = new S3Client({});

const BUCKET_NAME = process.env.OUTPUT_BUCKET || 'data-pipeline-output';

exports.handler = async (event) => {
  const failures = [];

  await Promise.all(event.Records.map(async (record) => {
    try {
      const payload = JSON.parse(record.body);
      const key = createS3Key(payload, record.messageId);

      // Idempotency check: skip records that were already successfully processed
      const alreadyProcessed = await objectExists(key);
      if (alreadyProcessed) {
        console.log(`Message ${record.messageId} already processed, skipping`);
        return;
      }

      const processed = transform(payload);

      await s3.send(new PutObjectCommand({
        Bucket: BUCKET_NAME,
        Key: key,
        Body: JSON.stringify(processed, null, 2),
        ContentType: 'application/json',
        Metadata: {
          'message-id': record.messageId,
          'processed-at': new Date().toISOString()
        }
      }));

      console.log(`Processed ${record.messageId} -> s3://${BUCKET_NAME}/${key}`);
    } catch (err) {
      console.error('Record failed', record.messageId, err.message);
      failures.push({ itemIdentifier: record.messageId });
    }
  }));

  return { batchItemFailures: failures };
};

function transform(payload) {
  return {
    id: payload.id || `event-${Date.now()}`,
    eventType: payload.eventType || 'unknown',
    timestamp: payload.timestamp || new Date().toISOString(),
    processedAt: new Date().toISOString(),
    payload: payload.data || payload
  };
}

function createS3Key(payload, messageId) {
  const date = new Date(payload.timestamp || Date.now());
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  // Use messageId as the filename fallback so the key is always unique
  const fileId = payload.id || messageId;
  const eventType = payload.eventType || 'unknown';
  return `processed/event_type=${eventType}/year=${year}/month=${month}/day=${day}/${fileId}.json`;
}

/**
 * Returns true if the S3 object already exists, false if it does not.
 * Throws only on unexpected errors (not on 404 NotFound).
 */
async function objectExists(key) {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: BUCKET_NAME, Key: key }));
    return true;
  } catch (err) {
    if (err.name === 'NotFound' || err.$metadata?.httpStatusCode === 404) {
      return false;
    }
    throw err;
  }
}
