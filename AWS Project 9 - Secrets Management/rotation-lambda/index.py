import boto3
import json

secretsmanager = boto3.client('secretsmanager')
rds = boto3.client('rds')


def lambda_handler(event, context):
    arn = event['SecretId']
    token = event['ClientRequestToken']
    step = event['Step']

    if step == 'createSecret':
        create_secret(arn, token)
    elif step == 'setSecret':
        set_secret(arn, token)
    elif step == 'testSecret':
        test_secret(arn, token)
    elif step == 'finishSecret':
        finish_secret(arn, token)
    else:
        raise ValueError('Invalid step parameter')


def create_secret(arn, token):
    current = get_secret_value(arn, 'AWSCURRENT')
    data = json.loads(current)

    new_password = generate_password()
    data['password'] = new_password

    secretsmanager.put_secret_value(
        SecretId=arn,
        ClientRequestToken=token,
        SecretString=json.dumps(data),
        VersionStages=['AWSPENDING']
    )


def set_secret(arn, token):
    pending = get_secret_value(arn, 'AWSPENDING', token)
    rds.modify_db_instance(
        DBInstanceIdentifier=pending['dbInstanceIdentifier'],
        MasterUserPassword=pending['password'],
        ApplyImmediately=True
    )


def test_secret(arn, token):
    import psycopg2
    pending = get_secret_value(arn, 'AWSPENDING', token)
    conn = psycopg2.connect(
        host=pending['host'],
        database=pending['dbname'],
        user=pending['username'],
        password=pending['password'],
        port=pending['port'],
        connect_timeout=5
    )
    conn.close()


def finish_secret(arn, token):
    secretsmanager.update_secret_version_stage(
        SecretId=arn,
        VersionStage='AWSCURRENT',
        MoveToVersionId=token,
        RemoveFromVersionId=get_version_id(arn, 'AWSCURRENT')
    )


def get_secret_value(arn, stage, token=None):
    if token:
        secret = secretsmanager.get_secret_value(SecretId=arn, VersionId=token, VersionStage=stage)
    else:
        secret = secretsmanager.get_secret_value(SecretId=arn, VersionStage=stage)
    return json.loads(secret['SecretString'])


def get_version_id(arn, stage):
    metadata = secretsmanager.describe_secret(SecretId=arn)
    for vid, stages in metadata['VersionIdsToStages'].items():
        if stage in stages:
            return vid
    return None


def generate_password(length=32):
    import secrets, string
    chars = string.ascii_letters + string.digits + '!@#$%^&*()'
    return ''.join(secrets.choice(chars) for _ in range(length))
