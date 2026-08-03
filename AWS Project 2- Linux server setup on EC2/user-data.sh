#!/bin/bash
# User Data Script for Project 2 - Linux Server Setup on EC2
# This script is executed when EC2 instance is launched
# Copy and paste into EC2 Launch Console -> Advanced Details -> User data

# Update system packages
apt-get update
apt-get upgrade -y

# Install required packages
apt-get install -y \
    curl \
    wget \
    git \
    python3 \
    python3-pip \
    python3-venv \
    ufw \
    htop \
    net-tools \
    unattended-upgrades

# Create application directory
mkdir -p /opt/webapp
cd /opt/webapp

# Create Python virtual environment
python3 -m venv venv
source venv/bin/activate

# Install Python dependencies
pip install --upgrade pip
pip install Flask==2.3.3 Werkzeug==2.3.7

# Create application files from base64 encoded content
# (In Console, you would copy the files directly)
cat > app.py << 'APPEOF'
from flask import Flask, render_template_string
import socket
from datetime import datetime

app = Flask(__name__)

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>EC2 Server Application</title>
    <style>
        body { font-family: Arial, sans-serif; max-width: 800px; margin: 50px auto; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); min-height: 100vh; }
        .container { background: white; border-radius: 10px; padding: 30px; box-shadow: 0 10px 25px rgba(0,0,0,0.2); }
        h1 { color: #333; border-bottom: 3px solid #667eea; padding-bottom: 10px; }
        .info-box { background: #f0f4ff; border-left: 4px solid #667eea; padding: 15px; margin: 15px 0; border-radius: 5px; }
        .label { font-weight: bold; color: #667eea; }
        .status { color: #28a745; font-weight: bold; }
    </style>
</head>
<body>
    <div class="container">
        <h1>✅ EC2 Linux Server is Running</h1>
        <div class="info-box">
            <p><span class="label">Server Status:</span> <span class="status">HEALTHY</span></p>
            <p><span class="label">Server Name:</span> {{ hostname }}</p>
            <p><span class="label">Server IP:</span> {{ ip_address }}</p>
            <p><span class="label">Current Time:</span> {{ current_time }}</p>
        </div>
    </div>
</body>
</html>
"""

@app.route('/')
def home():
    hostname = socket.gethostname()
    ip_address = socket.gethostbyname(hostname)
    current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
    return render_template_string(HTML_TEMPLATE, hostname=hostname, ip_address=ip_address, current_time=current_time)

@app.route('/health')
def health():
    return {'status': 'healthy'}, 200

if __name__ == '__main__':
    # Bind to 8080; nginx proxies port 80 → here so we never need root
    app.run(host='0.0.0.0', port=8080, debug=False)
APPEOF

# Install nginx as the public-facing port-80 listener
apt-get install -y nginx

cat > /etc/nginx/sites-available/webapp << 'NGINXEOF'
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /health {
        proxy_pass http://127.0.0.1:8080/health;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/webapp /etc/nginx/sites-enabled/webapp
rm -f /etc/nginx/sites-enabled/default
systemctl enable nginx
systemctl start nginx

# Create systemd service file for application
cat > /etc/systemd/system/webapp.service << 'SERVICEEOF'
[Unit]
Description=Flask Web Application
After=network.target

[Service]
Type=simple
User=www-data
WorkingDirectory=/opt/webapp
ExecStart=/opt/webapp/venv/bin/python app.py
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF

# Set up application directory permissions
chown -R www-data:www-data /opt/webapp
chmod 755 /opt/webapp

# Enable and start the service
systemctl daemon-reload
systemctl enable webapp.service
systemctl start webapp.service

# Configure UFW firewall
ufw --force enable
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp

# Enable CloudWatch agent monitoring (optional)
# Download and install the official CloudWatch agent package
wget -q https://s3.amazonaws.com/amazoncloudwatch-agent/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb
dpkg -i -E ./amazon-cloudwatch-agent.deb || true
rm -f amazon-cloudwatch-agent.deb

# Configure automatic security updates
apt-get install -y unattended-upgrades
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

# Log script completion
echo "EC2 Setup Complete: $(date)" >> /var/log/setup.log
