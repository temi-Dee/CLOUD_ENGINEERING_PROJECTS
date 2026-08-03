#!/usr/bin/env python3
"""
Simple Flask web application for Project 2 - Linux Server Setup on EC2
Demonstrates basic web server running on EC2 with security best practices
"""

from flask import Flask, render_template_string
import socket
import os
from datetime import datetime

app = Flask(__name__)

# HTML Template
HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>EC2 Server Application</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            max-width: 800px;
            margin: 50px auto;
            padding: 20px;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
        }
        .container {
            background: white;
            border-radius: 10px;
            padding: 30px;
            box-shadow: 0 10px 25px rgba(0,0,0,0.2);
        }
        h1 {
            color: #333;
            border-bottom: 3px solid #667eea;
            padding-bottom: 10px;
        }
        .info-box {
            background: #f0f4ff;
            border-left: 4px solid #667eea;
            padding: 15px;
            margin: 15px 0;
            border-radius: 5px;
        }
        .label {
            font-weight: bold;
            color: #667eea;
        }
        .status {
            color: #28a745;
            font-weight: bold;
        }
        .footer {
            margin-top: 30px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
            text-align: center;
            color: #666;
            font-size: 12px;
        }
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
            <p><span class="label">Uptime Check:</span> Application responding correctly</p>
        </div>

        <h2>Project 2: Linux Server Setup on EC2</h2>
        <p>This application demonstrates a hardened EC2 instance with:</p>
        <ul>
            <li>✓ Security Group configuration (port 80 and 22 only)</li>
            <li>✓ SSH key-based authentication</li>
            <li>✓ Firewall rules (UFW)</li>
            <li>✓ IAM role with minimal permissions</li>
            <li>✓ CloudWatch monitoring enabled</li>
            <li>✓ System updates applied</li>
            <li>✓ Nginx/Apache reverse proxy</li>
            <li>✓ Application running as non-root user</li>
        </ul>

        <h2>Next Steps</h2>
        <ol>
            <li>Monitor this instance in CloudWatch Console</li>
            <li>Check Security Group rules in EC2 Console</li>
            <li>View IAM role permissions in IAM Console</li>
            <li>SSH into instance for further configuration</li>
            <li>Scale to multiple instances with Load Balancer</li>
        </ol>

        <div class="footer">
            <p>AWS Project 2 - Linux Server Setup | Last refresh: {{ current_time }}</p>
        </div>
    </div>
</body>
</html>
"""

@app.route('/')
def home():
    """Serve the main application page"""
    hostname = socket.gethostname()
    ip_address = socket.gethostbyname(hostname)
    current_time = datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')
    
    return render_template_string(
        HTML_TEMPLATE,
        hostname=hostname,
        ip_address=ip_address,
        current_time=current_time
    )

@app.route('/health')
def health_check():
    """Health check endpoint for load balancers"""
    return {'status': 'healthy'}, 200

@app.route('/metrics')
def metrics():
    """Simple metrics endpoint"""
    return {
        'timestamp': datetime.now().isoformat(),
        'status': 'running',
        'service': 'Linux Server Application',
        'instance': socket.gethostname()
    }, 200

if __name__ == '__main__':
    # Run on 8080; nginx (running as root briefly to bind 80) proxies to this port
    app.run(host='0.0.0.0', port=8080, debug=False)
