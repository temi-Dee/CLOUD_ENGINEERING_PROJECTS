#!/bin/bash
set -eux

yum update -y
yum install -y nginx amazon-cloudwatch-agent

cat > /etc/nginx/conf.d/app.conf <<'NGINX'
server {
  listen 80;
  server_name _;

  location / {
    root /usr/share/nginx/html;
    index index.html;
  }

  location /health {
    return 200 'healthy';
    add_header Content-Type text/plain;
  }
}
NGINX

mkdir -p /usr/share/nginx/html

# Use IMDSv2 — get a short-lived token first, then fetch metadata with it
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
AZ=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/placement/availability-zone)

# Use an unquoted heredoc so that $INSTANCE_ID and $AZ are expanded at runtime.
cat > /usr/share/nginx/html/index.html <<HTML
<!DOCTYPE html>
<html>
<head><title>Auto Scaling Web Tier</title></head>
<body>
  <h1>Auto Scaling Web Tier</h1>
  <p>Instance ID: ${INSTANCE_ID}</p>
  <p>Availability Zone: ${AZ}</p>
  <p>Served at: $(date)</p>
</body>
</html>
HTML

systemctl enable nginx
systemctl start nginx
