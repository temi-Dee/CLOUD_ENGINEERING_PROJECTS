#!/bin/bash
# Project 7: Create Multi-Service Docker Application

set -e

echo "🚀 Creating Docker + ECS Multi-Service Application..."

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

APP_DIR="docker-ecs-app"

# Create project structure
echo -e "${BLUE}Creating project structure...${NC}"
mkdir -p $APP_DIR/{backend,frontend}

cd $APP_DIR

# Create backend service
echo -e "${BLUE}Creating backend service...${NC}"
cat > backend/package.json << 'EOF'
{
  "name": "backend-api",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "express": "^4.18.2",
    "pg": "^8.11.0",
    "cors": "^2.8.5"
  }
}
EOF

cat > backend/server.js << 'EOF'
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const app = express();
const PORT = process.env.PORT || 3000;

app.use(cors());
app.use(express.json());

const pool = new Pool({
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'postgres',
  user: process.env.DB_USER || 'postgres',
  password: process.env.DB_PASSWORD || 'postgres',
  port: 5432
});

app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    service: 'backend',
    timestamp: new Date().toISOString()
  });
});

app.get('/api/data', async (req, res) => {
  try {
    const result = await pool.query('SELECT NOW() as timestamp, version() as db_version');
    res.json({ 
      success: true,
      data: result.rows[0]
    });
  } catch (error) {
    res.status(500).json({ 
      success: false,
      error: error.message 
    });
  }
});

app.get('/api/items', async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM items ORDER BY id LIMIT 10');
    res.json({ 
      success: true,
      items: result.rows 
    });
  } catch (error) {
    res.json({ 
      success: false,
      items: [],
      message: 'Table not created yet'
    });
  }
});

app.post('/api/items', async (req, res) => {
  try {
    const { name, description } = req.body;
    const result = await pool.query(
      'INSERT INTO items (name, description) VALUES ($1, $2) RETURNING *',
      [name, description]
    );
    res.json({ 
      success: true,
      item: result.rows[0] 
    });
  } catch (error) {
    res.status(500).json({ 
      success: false,
      error: error.message 
    });
  }
});

app.listen(PORT, () => {
  console.log(`Backend API running on port ${PORT}`);
});
EOF

cat > backend/Dockerfile << 'EOF'
FROM node:18-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY . .

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:3000/health', (r) => {process.exit(r.statusCode === 200 ? 0 : 1)})"

CMD ["node", "server.js"]
EOF

# Create frontend service
echo -e "${BLUE}Creating frontend service...${NC}"
cat > frontend/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Docker ECS Multi-Service App</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            background: rgba(255,255,255,0.95);
            padding: 30px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
            margin-bottom: 30px;
        }
        h1 {
            color: #667eea;
            margin-bottom: 10px;
        }
        .subtitle {
            color: #666;
            font-size: 18px;
        }
        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(350px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .card {
            background: rgba(255,255,255,0.95);
            padding: 25px;
            border-radius: 15px;
            box-shadow: 0 10px 30px rgba(0,0,0,0.2);
        }
        .card h2 {
            color: #667eea;
            margin-bottom: 15px;
            font-size: 24px;
        }
        button {
            background: #667eea;
            color: white;
            border: none;
            padding: 12px 24px;
            border-radius: 8px;
            cursor: pointer;
            font-size: 16px;
            margin: 5px;
            transition: all 0.3s;
        }
        button:hover {
            background: #764ba2;
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(0,0,0,0.2);
        }
        .result {
            background: #f5f5f5;
            padding: 15px;
            border-radius: 8px;
            margin-top: 15px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            max-height: 300px;
            overflow-y: auto;
        }
        .status {
            display: inline-block;
            padding: 5px 15px;
            border-radius: 20px;
            font-size: 14px;
            font-weight: bold;
        }
        .status.healthy {
            background: #4caf50;
            color: white;
        }
        .status.error {
            background: #f44336;
            color: white;
        }
        input, textarea {
            width: 100%;
            padding: 10px;
            margin: 10px 0;
            border: 2px solid #ddd;
            border-radius: 8px;
            font-size: 14px;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🐳 Docker + ECS Multi-Service Application</h1>
            <p class="subtitle">Frontend (Nginx) → Backend (Node.js) → Database (PostgreSQL)</p>
        </div>

        <div class="grid">
            <div class="card">
                <h2>🏥 Health Check</h2>
                <button onclick="checkHealth()">Check Backend Health</button>
                <div id="health-result" class="result"></div>
            </div>

            <div class="card">
                <h2>📊 Database Info</h2>
                <button onclick="getDatabaseInfo()">Get Database Info</button>
                <div id="db-result" class="result"></div>
            </div>

            <div class="card">
                <h2>📝 Items List</h2>
                <button onclick="getItems()">Load Items</button>
                <div id="items-result" class="result"></div>
            </div>

            <div class="card">
                <h2>➕ Add Item</h2>
                <input type="text" id="item-name" placeholder="Item name">
                <textarea id="item-description" placeholder="Item description" rows="3"></textarea>
                <button onclick="addItem()">Add Item</button>
                <div id="add-result" class="result"></div>
            </div>
        </div>
    </div>

    <script>
        const API_URL = window.location.origin;

        async function checkHealth() {
            const result = document.getElementById('health-result');
            try {
                const response = await fetch(`${API_URL}/api/health`);
                const data = await response.json();
                result.innerHTML = `
                    <div class="status healthy">✓ Healthy</div>
                    <pre>${JSON.stringify(data, null, 2)}</pre>
                `;
            } catch (error) {
                result.innerHTML = `
                    <div class="status error">✗ Error</div>
                    <pre>${error.message}</pre>
                `;
            }
        }

        async function getDatabaseInfo() {
            const result = document.getElementById('db-result');
            try {
                const response = await fetch(`${API_URL}/api/data`);
                const data = await response.json();
                result.innerHTML = `<pre>${JSON.stringify(data, null, 2)}</pre>`;
            } catch (error) {
                result.innerHTML = `<pre>Error: ${error.message}</pre>`;
            }
        }

        async function getItems() {
            const result = document.getElementById('items-result');
            try {
                const response = await fetch(`${API_URL}/api/items`);
                const data = await response.json();
                result.innerHTML = `<pre>${JSON.stringify(data, null, 2)}</pre>`;
            } catch (error) {
                result.innerHTML = `<pre>Error: ${error.message}</pre>`;
            }
        }

        async function addItem() {
            const name = document.getElementById('item-name').value;
            const description = document.getElementById('item-description').value;
            const result = document.getElementById('add-result');

            if (!name) {
                result.innerHTML = '<pre>Please enter an item name</pre>';
                return;
            }

            try {
                const response = await fetch(`${API_URL}/api/items`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ name, description })
                });
                const data = await response.json();
                result.innerHTML = `<pre>${JSON.stringify(data, null, 2)}</pre>`;
                
                if (data.success) {
                    document.getElementById('item-name').value = '';
                    document.getElementById('item-description').value = '';
                }
            } catch (error) {
                result.innerHTML = `<pre>Error: ${error.message}</pre>`;
            }
        }

        // Auto-check health on load
        window.onload = () => checkHealth();
    </script>
</body>
</html>
EOF

cat > frontend/nginx.conf << 'EOF'
server {
    listen 80;
    server_name _;

    location / {
        root /usr/share/nginx/html;
        index index.html;
        try_files $uri $uri/ /index.html;
    }

    location /api/ {
        proxy_pass http://backend:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
EOF

cat > frontend/Dockerfile << 'EOF'
FROM nginx:alpine

COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost/ || exit 1

CMD ["nginx", "-g", "daemon off;"]
EOF

# Create docker-compose for local testing
cat > docker-compose.yml << 'EOF'
version: '3.8'

services:
  backend:
    build: ./backend
    ports:
      - "3000:3000"
    environment:
      - PORT=3000
      - DB_HOST=postgres
      - DB_NAME=appdb
      - DB_USER=postgres
      - DB_PASSWORD=postgres
    depends_on:
      - postgres
    networks:
      - app-network

  frontend:
    build: ./frontend
    ports:
      - "80:80"
    depends_on:
      - backend
    networks:
      - app-network

  postgres:
    image: postgres:15-alpine
    environment:
      - POSTGRES_DB=appdb
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=postgres
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    networks:
      - app-network

volumes:
  postgres-data:

networks:
  app-network:
    driver: bridge
EOF

# Create database init script
cat > init.sql << 'EOF'
CREATE TABLE IF NOT EXISTS items (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO items (name, description) VALUES
    ('Sample Item 1', 'This is a sample item'),
    ('Sample Item 2', 'Another sample item'),
    ('Sample Item 3', 'Yet another sample item');
EOF

# Create deployment script
cat > deploy-to-ecs.sh << 'EOF'
#!/bin/bash
# Deploy to AWS ECS

set -e

echo "🚀 Deploying to AWS ECS..."

# Variables
REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Create ECR repositories
echo "Creating ECR repositories..."
aws ecr create-repository --repository-name backend-api --region $REGION 2>/dev/null || true
aws ecr create-repository --repository-name frontend-web --region $REGION 2>/dev/null || true

# Get repository URIs
BACKEND_REPO=$(aws ecr describe-repositories --repository-names backend-api --query 'repositories[0].repositoryUri' --output text --region $REGION)
FRONTEND_REPO=$(aws ecr describe-repositories --repository-names frontend-web --query 'repositories[0].repositoryUri' --output text --region $REGION)

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com

# Build and push images
echo "Building and pushing backend..."
cd backend
docker build -t backend-api .
docker tag backend-api:latest $BACKEND_REPO:latest
docker push $BACKEND_REPO:latest
cd ..

echo "Building and pushing frontend..."
cd frontend
docker build -t frontend-web .
docker tag frontend-web:latest $FRONTEND_REPO:latest
docker push $FRONTEND_REPO:latest
cd ..

echo "✓ Images pushed to ECR"
echo "Backend: $BACKEND_REPO:latest"
echo "Frontend: $FRONTEND_REPO:latest"
echo ""
echo "Next: Follow README to create ECS cluster and services"
EOF

chmod +x deploy-to-ecs.sh

# Create README
cat > README.md << 'EOF'
# Docker + ECS Multi-Service Application

Complete containerized application with frontend, backend, and database.

## Local Development

```bash
# Build and run with Docker Compose
docker-compose up --build

# Access application
open http://localhost
```

## Deploy to AWS ECS

```bash
# Push images to ECR
./deploy-to-ecs.sh

# Then follow Project 7 README to:
# 1. Create ECS cluster
# 2. Create task definitions
# 3. Create ALB
# 4. Create ECS services
```

## Architecture

- **Frontend**: Nginx serving static HTML
- **Backend**: Node.js Express API
- **Database**: PostgreSQL

## API Endpoints

- `GET /api/health` - Health check
- `GET /api/data` - Database info
- `GET /api/items` - List items
- `POST /api/items` - Create item
EOF

cd ..

echo -e "${GREEN}✓ Docker application created: $APP_DIR${NC}"
echo ""
echo "Next steps:"
echo "1. cd $APP_DIR"
echo "2. docker-compose up --build"
echo "3. Open http://localhost"
echo "4. ./deploy-to-ecs.sh (to deploy to AWS)"
echo ""
