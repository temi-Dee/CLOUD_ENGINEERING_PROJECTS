const http = require('http');
const { CodeDeployClient, PutLifecycleEventHookExecutionStatusCommand } = require('@aws-sdk/client-codedeploy');

const codedeploy = new CodeDeployClient({});

/**
 * CodeDeploy lifecycle hook handler.
 *
 * CodeDeploy invokes this Lambda for the AfterAllowTestTraffic hook.
 * The function MUST call putLifecycleEventHookExecutionStatus with either
 * 'Succeeded' or 'Failed' — otherwise the deployment will time out and fail.
 *
 * Environment variables:
 *   ALB_DNS  — DNS name of the Application Load Balancer (no protocol prefix)
 */
exports.handler = async (event) => {
  console.log('Deployment validation event:', JSON.stringify(event));

  const deploymentId = event.DeploymentId;
  const lifecycleEventHookExecutionId = event.LifecycleEventHookExecutionId;
  const albDns = process.env.ALB_DNS;

  if (!albDns) {
    await reportStatus(deploymentId, lifecycleEventHookExecutionId, 'Failed');
    throw new Error('ALB_DNS environment variable is required');
  }

  // Validate the new (green) environment via the test listener on port 8080
  const healthy = await checkHealth(`http://${albDns}:8080/health`);
  const status = healthy ? 'Succeeded' : 'Failed';

  console.log(`Health check result: ${status}`);
  await reportStatus(deploymentId, lifecycleEventHookExecutionId, status);

  if (!healthy) {
    throw new Error('Deployment health check failed — triggering rollback');
  }

  return { status: 'SUCCEEDED' };
};

function checkHealth(url) {
  return new Promise((resolve) => {
    const req = http.get(url, (res) => {
      let body = '';
      res.on('data', (chunk) => { body += chunk; });
      res.on('end', () => {
        try {
          const parsed = JSON.parse(body);
          resolve(res.statusCode === 200 && parsed.status === 'healthy');
        } catch {
          resolve(res.statusCode === 200);
        }
      });
    });

    req.on('error', (err) => {
      console.error('Health check request error:', err.message);
      resolve(false);
    });

    // Fail fast — do not wait longer than 10 seconds
    req.setTimeout(10000, () => {
      console.error('Health check timed out');
      req.destroy();
      resolve(false);
    });
  });
}

async function reportStatus(deploymentId, lifecycleEventHookExecutionId, status) {
  try {
    await codedeploy.send(new PutLifecycleEventHookExecutionStatusCommand({
      deploymentId,
      lifecycleEventHookExecutionId,
      status
    }));
    console.log(`Reported lifecycle hook status: ${status}`);
  } catch (err) {
    console.error('Failed to report lifecycle hook status:', err.message);
    throw err;
  }
}
