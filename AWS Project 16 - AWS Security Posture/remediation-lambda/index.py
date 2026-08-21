import os
import boto3
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client('s3')
ec2 = boto3.client('ec2')
sns = boto3.client('sns')


def lambda_handler(event, context):
    logger.info(f'Received event: {json.dumps(event)}')
    findings = event.get('detail', {}).get('findings', [])

    for finding in findings:
        title = finding.get('Title', '')
        severity = finding.get('Severity', {}).get('Label', 'UNKNOWN')
        resources = finding.get('Resources', [])

        if 'S3 bucket should not have public read access' in title:
            for resource in resources:
                bucket_name = resource.get('Id', '').split(':::')[-1]
                remediate_s3(bucket_name)

        if 'Security groups should not allow unrestricted access to port 22' in title:
            for resource in resources:
                # Security Hub Resource.Id is a full ARN; extract the SG ID after the final '/'
                sg_id = resource.get('Id', '').split('/')[-1]
                remediate_ssh(sg_id)

        if severity in ['CRITICAL', 'HIGH']:
            send_alert(f'Security finding [{severity}]: {title}', severity)

    return {'status': 'completed'}


def remediate_s3(bucket_name):
    if not bucket_name:
        return
    try:
        s3.put_public_access_block(
            Bucket=bucket_name,
            PublicAccessBlockConfiguration={
                'BlockPublicAcls': True,
                'IgnorePublicAcls': True,
                'BlockPublicPolicy': True,
                'RestrictPublicBuckets': True
            }
        )
        logger.info(f'Blocked public access on bucket: {bucket_name}')
    except Exception as e:
        logger.error(f'Failed to remediate S3 bucket {bucket_name}: {e}')


def remediate_ssh(sg_id):
    if not sg_id:
        return
    try:
        ec2.revoke_security_group_ingress(
            GroupId=sg_id,
            IpPermissions=[{
                'IpProtocol': 'tcp',
                'FromPort': 22,
                'ToPort': 22,
                'IpRanges': [{'CidrIp': '0.0.0.0/0'}]
            }]
        )
        logger.info(f'Removed open SSH from security group: {sg_id}')
    except Exception as e:
        logger.error(f'Failed to remediate security group {sg_id}: {e}')


def send_alert(message, severity):
    topic_arn = os.environ.get('ALERT_TOPIC_ARN')
    if not topic_arn:
        logger.warning('ALERT_TOPIC_ARN environment variable is not set; skipping SNS alert')
        return
    try:
        sns.publish(
            TopicArn=topic_arn,
            Subject=f'AWS Security Alert [{severity}]',
            Message=message
        )
    except Exception as e:
        logger.error(f'Failed to send SNS alert: {e}')
