# Project 2: Linux Server Setup on EC2

## Overview

A secure EC2 instance is the foundation of many AWS workloads. In this project you will use the AWS Management Console to launch a hardened Linux server with best practices built in. This includes creating security groups, IAM roles, key pairs, and deploying a Python Flask web application through the EC2 user data script. No AWS CLI is required for the console-based steps; an optional CLI/automation section is provided at the end.

## Prerequisites

Before starting this project, ensure you have:

1. An AWS account with EC2 and IAM console access
2. A web browser to access the AWS Management Console
3. Access to the project files: `app.py`, `requirements.txt`, and `user-data.sh`
4. Basic Linux and networking knowledge
5. Optional: an SSH client for direct SSH access (Session Manager is also available)

## Project Structure

```
AWS Project 2 - Linux Server Setup on EC2/
├── app.py            # Flask web application
├── requirements.txt  # Python dependencies
├── user-data.sh      # EC2 user data startup script
├── deploy.sh         # Automated CLI deployment script
├── cleanup.sh        # Automated CLI cleanup script
└── README.md
```

## Steps

### 1. Create an EC2 Security Group

1. Open the AWS Console and navigate to EC2 Dashboard.
2. In the left sidebar, click Security Groups under "Network & Security".
3. Click Create security group.
4. Enter:
   - Security group name: `project2-web-server-sg`
   - Description: `Security group for Project 2 EC2 web server`
   - VPC: Select your default VPC
5. Under Inbound rules, add three rules:
   - SSH | Port 22 | Source: your IP address (or `0.0.0.0/0` for testing only)
   - HTTP | Port 80 | Source: `0.0.0.0/0`
   - HTTPS | Port 443 | Source: `0.0.0.0/0`
6. Click Create security group.

### 2. Create an IAM Role for EC2

1. Open the AWS Console and navigate to IAM Dashboard.
2. Click Roles in the left sidebar, then Create role.
3. Select AWS service and choose EC2. Click Next.
4. Attach the following policies:
   - `CloudWatchAgentServerPolicy`
   - `AmazonSSMManagedInstanceCore`
5. Click Next, enter the role name `Project2-EC2-Role`, then click Create role.

### 3. Create an EC2 Key Pair

1. In the EC2 Console, click Key Pairs under "Network & Security".
2. Click Create key pair.
3. Enter:
   - Name: `project2-key`
   - Key pair type: RSA
   - Private key file format: `.pem`
4. Click Create key pair and save `project2-key.pem` securely.

### 4. Launch the EC2 Instance

1. In the EC2 Dashboard, click Launch instances.
2. Configure:
   - Name: `Project2-Web-Server`
   - AMI: Ubuntu Server 22.04 LTS
   - Instance type: `t2.micro`
   - Key pair: `project2-key`
   - Network settings: default VPC, security group `project2-web-server-sg`
   - Auto-assign public IP: Enable
3. Scroll to Advanced details:
   - IAM instance profile: `Project2-EC2-Role`
   - User data: paste the contents of `user-data.sh`
4. Click Launch instance.

### 5. Monitor Instance Startup

1. In EC2 Dashboard, click Instances.
2. Select `Project2-Web-Server`.
3. Wait for:
   - Instance state: Running
   - Status checks: 2/2 passed
4. Copy the Public IPv4 address from the instance details panel.

### 6. Access the Web Application

1. Open a browser tab and enter `http://<PUBLIC_IP>`.
2. Confirm the application shows:
   - Server Status: HEALTHY
   - Server Name
   - Server IP
   - Current Time

### 7. Connect to the Instance via Session Manager (Optional)

1. In the EC2 Dashboard, select the instance.
2. Click Connect.
3. Choose Session Manager and click Connect.
4. A browser-based terminal opens with no SSH key required.

### 8. Monitor Metrics in CloudWatch

1. Open the CloudWatch Console.
2. Click Instances in the left sidebar.
3. Select your instance.
4. Review metrics: CPU utilization, network, disk I/O, and status check failures.

## Console Deployment

Steps 1–8 above are the complete AWS Management Console deployment path. Use this quick reference and cleanup guide alongside them.

### Quick Reference

| Step | Service | Action |
|------|---------|--------|
| 1 | EC2 → Security Groups → Create | Name: `project2-web-server-sg`, add SSH/HTTP/HTTPS inbound rules |
| 2 | IAM → Roles → Create role | AWS service → EC2, attach `CloudWatchAgentServerPolicy` + `AmazonSSMManagedInstanceCore`, name: `Project2-EC2-Role` |
| 3 | EC2 → Key Pairs → Create | Name: `project2-key`, RSA, .pem format — save securely |
| 4 | EC2 → Launch instances | Ubuntu 22.04, t2.micro, attach key pair + SG + IAM role, paste `user-data.sh` in Advanced details |
| 5 | EC2 → Instances | Wait for 2/2 status checks, copy Public IPv4 address |
| 6 | Browser | Open `http://<PUBLIC_IP>` and confirm healthy response |
| 7 | EC2 → Connect → Session Manager | Browser terminal, no SSH key required |
| 8 | CloudWatch → Instances | Review CPU, network, disk metrics |

### Console Cleanup

1. Go to **EC2 → Instances** → select `Project2-Web-Server` → **Instance state → Terminate instance**
2. Wait for termination, then go to **EC2 → Security Groups** → delete `project2-web-server-sg`
3. Go to **EC2 → Key Pairs** → delete `project2-key`
4. Go to **IAM → Roles** → delete `Project2-EC2-Role`

---

## CLI / Automation

Use `deploy.sh` to create all resources automatically with the AWS CLI:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script performs these steps in order:

1. Creates an IAM role (`WebServerRole`) and instance profile (`WebServerProfile`) with `CloudWatchAgentServerPolicy`
2. Creates a key pair (`web-server-key`) and saves the `.pem` file locally
3. Creates a security group (`web-server-sg`) and opens ports 22 (your IP only), 80, and 443
4. Looks up the latest Amazon Linux 2023 AMI for your region
5. Launches the EC2 instance with Nginx configured via user data
6. Waits for the instance to reach the running state and prints the public IP

Instance details are saved to `instance-info.txt` for use by the cleanup script.

## Cleanup

Run `cleanup.sh` to terminate all resources:

```bash
chmod +x cleanup.sh
./cleanup.sh
```

The script reads `instance-info.txt` and:
- Terminates the EC2 instance and waits for full termination
- Deletes the security group
- Deletes the key pair and local `.pem` file
- Removes the IAM role and instance profile

## Testing and Validation

After deployment, validate the setup:

1. Open `http://<PUBLIC_IP>` in your browser and confirm the application responds.
2. Test the health endpoint: `curl http://<PUBLIC_IP>/health`
3. Verify SSH key authentication works: `ssh -i web-server-key.pem ec2-user@<PUBLIC_IP>`
4. Confirm password authentication is rejected (SSH hardening).
5. Check instance status in the EC2 Console (2/2 status checks should pass).
6. Review `/var/log/cloud-init-output.log` via Session Manager if the app does not start.

## Learning Objectives

After completing this project, you will understand:

- Launching EC2 instances using the AWS Console
- Creating and managing security groups
- Assigning IAM roles to EC2 instances
- Using key pairs for secure SSH access
- Automating server configuration with EC2 user data
- Checking instance health and metrics in CloudWatch
- Using Session Manager for secure browser-based terminal access

## Troubleshooting

| Problem | Solution |
|---|---|
| Instance status checks fail | Wait 2-3 minutes; review the instance system log and `/var/log/cloud-init-output.log` |
| Web page does not load | Verify the security group allows port 80 and the instance has a public IP |
| User data script did not run | Connect via Session Manager and inspect `/var/log/cloud-init-output.log` |
| Cannot SSH | Confirm the security group allows port 22, the key file has `chmod 400`, and you are using the correct username (`ec2-user` for Amazon Linux, `ubuntu` for Ubuntu) |
