import os
import boto3
import json
import logging
from datetime import datetime, timedelta, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2 = boto3.client('ec2')
cloudwatch = boto3.client('cloudwatch')
sns = boto3.client('sns')

# Set via Lambda environment variable
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN', '')


def lambda_handler(event, context):
    findings = []
    total_savings = 0.0

    # 1. Unattached EBS volumes (status=available)
    volumes = ec2.describe_volumes(
        Filters=[{'Name': 'status', 'Values': ['available']}]
    )
    for vol in volumes['Volumes']:
        savings = vol['Size'] * 0.10  # $0.10/GB-month for gp3
        findings.append({
            'type': 'Unattached EBS Volume',
            'resource': vol['VolumeId'],
            'details': f"{vol['Size']} GB",
            'savings': round(savings, 2)
        })
        total_savings += savings

    # 2. Unused Elastic IPs (not associated with any instance)
    addresses = ec2.describe_addresses()
    for addr in addresses['Addresses']:
        if 'InstanceId' not in addr:
            findings.append({
                'type': 'Unused Elastic IP',
                'resource': addr.get('PublicIp', addr['AllocationId']),
                'details': 'Not associated with any instance',
                'savings': 3.65  # $0.005/hour * 730 hours/month
            })
            total_savings += 3.65

    # 3. Old EBS snapshots (older than 30 days)
    cutoff = datetime.now(timezone.utc) - timedelta(days=30)
    snapshots = ec2.describe_snapshots(OwnerIds=['self'])
    for snap in snapshots['Snapshots']:
        start_time = snap['StartTime']
        if start_time.tzinfo is None:
            start_time = start_time.replace(tzinfo=timezone.utc)
        if start_time < cutoff:
            savings = snap['VolumeSize'] * 0.05  # $0.05/GB-month for snapshot storage
            age_days = (datetime.now(timezone.utc) - start_time).days
            findings.append({
                'type': 'Old Snapshot (>30 days)',
                'resource': snap['SnapshotId'],
                'details': f"{snap['VolumeSize']} GB, {age_days} days old",
                'savings': round(savings, 2)
            })
            total_savings += savings

    # 4. Idle EC2 instances (average CPU < 5% over 7 days)
    instances = ec2.describe_instances(
        Filters=[{'Name': 'instance-state-name', 'Values': ['running']}]
    )
    for reservation in instances['Reservations']:
        for instance in reservation['Instances']:
            instance_id = instance['InstanceId']
            metrics = cloudwatch.get_metric_statistics(
                Namespace='AWS/EC2',
                MetricName='CPUUtilization',
                Dimensions=[{'Name': 'InstanceId', 'Value': instance_id}],
                StartTime=datetime.now(timezone.utc) - timedelta(days=7),
                EndTime=datetime.now(timezone.utc),
                Period=86400,
                Statistics=['Average']
            )
            if metrics['Datapoints']:
                avg_cpu = (
                    sum(d['Average'] for d in metrics['Datapoints'])
                    / len(metrics['Datapoints'])
                )
                if avg_cpu < 5.0:
                    # Use $50 as a conservative placeholder; use the Pricing API for accuracy
                    estimated_savings = 50.0
                    findings.append({
                        'type': 'Idle EC2 Instance',
                        'resource': instance_id,
                        'details': f"{instance['InstanceType']}, avg CPU {avg_cpu:.1f}%",
                        'savings': estimated_savings
                    })
                    total_savings += estimated_savings

    # 5. Empty S3 buckets (no objects — no storage cost but operational overhead)
    s3 = boto3.client('s3')
    buckets = s3.list_buckets()
    for bucket in buckets.get('Buckets', []):
        bucket_name = bucket['Name']
        try:
            objects = s3.list_objects_v2(Bucket=bucket_name, MaxKeys=1)
            if objects.get('KeyCount', 0) == 0:
                findings.append({
                    'type': 'Empty S3 Bucket',
                    'resource': bucket_name,
                    'details': 'Contains no objects',
                    'savings': 0.0
                })
        except Exception as e:
            logger.warning(f'Could not inspect bucket {bucket_name}: {e}')

    # Build and send report
    report_lines = [
        'AWS Cost Optimization Report',
        f'Generated: {datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")} UTC',
        '',
        f'Total Potential Monthly Savings: ${total_savings:.2f}',
        f'Total Findings: {len(findings)}',
        '',
    ]
    for finding in findings:
        line = f"- {finding['type']}: {finding['resource']} ({finding.get('details', '')})"
        if finding.get('savings', 0) > 0:
            line += f" | Save ${finding['savings']:.2f}/month"
        report_lines.append(line)

    report = '\n'.join(report_lines)
    logger.info(report)

    if SNS_TOPIC_ARN and findings:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject='AWS Cost Optimization Report',
            Message=report
        )

    return {
        'statusCode': 200,
        'body': json.dumps({
            'findings_count': len(findings),
            'total_potential_savings': round(total_savings, 2)
        })
    }
