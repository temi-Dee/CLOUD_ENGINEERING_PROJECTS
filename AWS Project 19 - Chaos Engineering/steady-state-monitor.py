import os
import boto3
import json
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cloudwatch = boto3.client('cloudwatch')
fis = boto3.client('fis')

# ALB identifier in the form app/<alb-name>/<id> — set via Lambda environment variable
ALB_DIMENSION = os.environ.get('ALB_DIMENSION', '')

# TargetResponseTime is reported in seconds; 0.5 = 500 ms
LATENCY_THRESHOLD_SECONDS = float(os.environ.get('LATENCY_THRESHOLD_SECONDS', '0.5'))


def lambda_handler(event, context):
    if not ALB_DIMENSION:
        logger.error('ALB_DIMENSION environment variable is not set')
        return {'error': 'ALB_DIMENSION not configured'}

    now = datetime.now(timezone.utc)
    start = now - timedelta(minutes=5)

    response = cloudwatch.get_metric_statistics(
        Namespace='AWS/ApplicationELB',
        MetricName='TargetResponseTime',
        Dimensions=[{'Name': 'LoadBalancer', 'Value': ALB_DIMENSION}],
        StartTime=start,
        EndTime=now,
        Period=300,
        Statistics=['Average']
    )

    datapoints = response.get('Datapoints', [])
    avg_latency = datapoints[0]['Average'] if datapoints else 0.0

    logger.info(f'Average latency over last 5 minutes: {avg_latency:.4f}s '
                f'(threshold: {LATENCY_THRESHOLD_SECONDS}s)')

    if avg_latency > LATENCY_THRESHOLD_SECONDS:
        logger.warning(f'Steady-state violated — stopping all running FIS experiments')
        experiments = fis.list_experiments(maxResults=100)
        for exp in experiments.get('experiments', []):
            if exp.get('state', {}).get('status') == 'running':
                fis.stop_experiment(id=exp['id'])
                logger.info(f"Stopped experiment {exp['id']}")

    return {
        'averageLatencySeconds': round(avg_latency, 4),
        'thresholdSeconds': LATENCY_THRESHOLD_SECONDS,
        'steadyStateOk': avg_latency <= LATENCY_THRESHOLD_SECONDS
    }
