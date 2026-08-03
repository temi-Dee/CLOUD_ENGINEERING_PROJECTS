# Daniel Ayodele — AWS Cloud Engineer & Cybersecurity Portfolio

> Personal portfolio and technical blog built with HTML, CSS, and JavaScript, hosted on AWS using S3, CloudFront, Route 53, and ACM.

---

## About This Project

This is **Project 01** of my AWS Cloud Engineering journey.

The goal was to build and deploy a personal portfolio/blog website entirely on AWS using core cloud services. The site showcases my AWS projects, cybersecurity write-ups, hands-on labs, skills, and contact information.

**Live at:** `https://your-domain.com` *(replace with your actual domain once deployed)*

---

## What I Built

| Page | Description |
|------|-------------|
| `index.html` | Homepage — hero, projects, cybersecurity, labs, skills, about |
| `contact.html` | Contact page — form, sidebar with social links and availability |
| `css/styles.css` | Full site styling with glassmorphism dark theme |
| `js/main.js` | Hamburger nav, form validation, WhatsApp + email integration |
| `assets/daniel.png` | Profile photo used in the About section |

---

## AWS Services Used

| Service | Purpose |
|---------|---------|
| **Amazon S3** | Static website hosting — stores and serves all HTML, CSS, JS, and image files |
| **Amazon CloudFront** | CDN — global content delivery, HTTPS enforcement, caching |
| **AWS Certificate Manager (ACM)** | Free SSL/TLS certificate for HTTPS on custom domain |
| **Amazon Route 53** | DNS management — routes custom domain to CloudFront distribution |

---

## What I Learned

- **S3 Bucket Policies** — how to write JSON policies to allow public read access to static files
- **CDN Concepts** — how CloudFront caches content at edge locations globally for faster load times
- **DNS Management** — how to create A records and alias records in Route 53 to point a domain to CloudFront
- **HTTPS with ACM** — how to request, validate, and attach a free SSL certificate to a CloudFront distribution
- **Static Website Hosting** — the difference between S3 REST endpoint and S3 website endpoint, and why CloudFront uses the website endpoint as origin

---

## Project Structure

```
AWS Project 1/
├── assets/
│   └── daniel.png          # Profile photo
├── css/
│   └── styles.css          # Glassmorphism dark theme styles
├── js/
│   └── main.js             # Nav toggle, form validation, WhatsApp/email
├── index.html              # Main portfolio homepage
├── contact.html            # Contact page
└── README.md               # This file
```

---

## Deployment Guide

### Prerequisites

- AWS account (free tier is sufficient)
- A registered domain in Route 53 (e.g. `danielayodele.cloud`)
- AWS CLI installed and configured: `aws configure`

---

### Step 1 — Create and Configure the S3 Bucket

1. Go to **S3** in the AWS Console → **Create bucket**
2. Give it a globally unique name, e.g. `daniel-portfolio-2026`
3. **Uncheck** "Block all public access" → confirm
4. Go to **Properties** → **Static website hosting** → Enable
   - Index document: `index.html`
   - Error document: `index.html`
5. Go to **Permissions** → **Bucket policy** → paste this:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PublicReadGetObject",
      "Effect": "Allow",
      "Principal": "*",
      "Action": "s3:GetObject",
      "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
    }
  ]
}
```

> Replace `YOUR_BUCKET_NAME` with your actual bucket name.

6. Upload all project files:

```powershell
aws s3 sync . "s3://YOUR_BUCKET_NAME" --exclude ".git/*" --exclude "README.md"
```

7. Copy the **Bucket website endpoint** from Properties and test it in your browser.

---

### Step 2 — Request an SSL Certificate in ACM

> **Important:** ACM certificates for CloudFront must be created in **us-east-1 (N. Virginia)** regardless of your region.

1. Go to **AWS Certificate Manager** → switch region to **us-east-1**
2. Click **Request a public certificate**
3. Add domain names:
   - `yourdomain.com`
   - `www.yourdomain.com`
4. Choose **DNS validation**
5. Click **Create records in Route 53** — AWS adds the CNAME records automatically
6. Wait for status to show **Issued** (usually 2–5 minutes)

---

### Step 3 — Create a CloudFront Distribution

1. Go to **CloudFront** → **Create distribution**
2. **Origin domain:** paste your S3 **website endpoint** (not the bucket ARN)
   - Format: `YOUR_BUCKET_NAME.s3-website-REGION.amazonaws.com`
3. **Viewer protocol policy:** Redirect HTTP to HTTPS
4. **Alternate domain names (CNAMEs):** add `yourdomain.com` and `www.yourdomain.com`
5. **Custom SSL certificate:** select the ACM certificate you created
6. **Default root object:** `index.html`
7. Click **Create distribution**

> CloudFront deployment takes 5–15 minutes. The distribution domain will look like `d1234abcd.cloudfront.net`.

---

### Step 4 — Configure Route 53 DNS

1. Go to **Route 53** → **Hosted zones** → select your domain
2. Create an **A record** for the root domain:
   - Record name: *(leave blank for root)*
   - Record type: **A**
   - Alias: **Yes**
   - Route traffic to: **Alias to CloudFront distribution**
   - Select your distribution
3. Create another **A record** for `www`:
   - Record name: `www`
   - Same alias settings pointing to CloudFront
4. Save both records

---

### Step 5 — Verify Everything Works

- [ ] Open `https://yourdomain.com` — site loads with padlock (HTTPS)
- [ ] Open `https://www.yourdomain.com` — redirects correctly
- [ ] Navigate to `/contact.html` — contact page loads
- [ ] Submit the contact form — email client opens + WhatsApp opens
- [ ] Click the floating WhatsApp button — opens chat with `+2349039062561`
- [ ] Test on mobile — hamburger menu works, layout is responsive

---

### Updating the Site After Changes

After making changes to any files, sync to S3 and invalidate the CloudFront cache:

```powershell
# Upload updated files
aws s3 sync . "s3://YOUR_BUCKET_NAME" --exclude ".git/*" --exclude "README.md"

# Invalidate CloudFront cache so changes go live immediately
aws cloudfront create-invalidation --distribution-id YOUR_DISTRIBUTION_ID --paths "/*"
```

---

## Contact & Social

| Platform | Link |
|----------|------|
| Email | ayodeledaniel0240@gmail.com |
| LinkedIn | [linkedin.com/in/danielayodele0420](https://www.linkedin.com/in/danielayodele0420/) |
| GitHub | [github.com/temi-Dee](https://github.com/temi-Dee) |
| WhatsApp | +234 903 906 2561 |

---

## Roadmap — Upcoming Projects

As I progress through my AWS Cloud Engineering journey, I will add:

- [ ] Project 02 — Secure VPC Architecture (EC2, subnets, NAT Gateway, Security Groups)
- [ ] Project 03 — EC2 Auto Scaling with ALB and CloudWatch Alarms
- [ ] Project 04 — IAM Security Best Practices (least privilege, MFA, SCPs)
- [ ] Project 05 — Serverless API with Lambda, API Gateway, and DynamoDB
- [ ] Project 06 — CI/CD Pipeline with GitHub Actions and AWS ECS

---

*Built by Daniel Ayodele — AWS Cloud Engineer & Cybersecurity Enthusiast*
