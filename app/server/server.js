const express = require('express');
const mysql = require('mysql2');
const cors = require('cors');

const app = express();
const port = process.env.PORT || 5000;

// Middleware
app.use(cors());
app.use(express.json());

// Database connection with retry logic
const dbConfig = {
  host: process.env.DB_HOST || 'localhost',
  user: process.env.DB_USER || 'appuser',
  password: process.env.DB_PASSWORD || 'password123',
  database: process.env.DB_NAME || 'test_db',
};

let db;

function connectWithRetry() {
  db = mysql.createConnection(dbConfig);

  db.connect((err) => {
    if (err) {
      console.error('Database connection failed, retrying in 5s...', err.message);
      setTimeout(connectWithRetry, 5000);
      return;
    }
    console.log('Database connected.');

    const createUsersTable = `
      CREATE TABLE IF NOT EXISTS users (
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(255) NOT NULL,
        email VARCHAR(255) NOT NULL UNIQUE,
        role ENUM('Admin', 'User') NOT NULL
      )
    `;

    db.query(createUsersTable, (err) => {
      if (err) {
        console.error('Failed to create users table:', err.message);
        return;
      }
      console.log('Users table ready.');
    });
  });

  db.on('error', (err) => {
    console.error('Database error:', err.message);
    if (err.code === 'PROTOCOL_CONNECTION_LOST') {
      console.log('Reconnecting to database...');
      connectWithRetry();
    } else {
      throw err;
    }
  });
}

connectWithRetry();

// Health check — K8s liveness and readiness probes
app.get('/api/health', (req, res) => {
  if (!db || db.state === 'disconnected') {
    return res.status(503).json({ status: 'unhealthy', reason: 'database disconnected' });
  }
  db.ping((err) => {
    if (err) {
      return res.status(503).json({ status: 'unhealthy', reason: err.message });
    }
    res.json({ status: 'healthy' });
  });
});

// API Routes
app.get('/api/users', (req, res) => {
  db.query('SELECT * FROM users', (err, results) => {
    if (err) {
      return res.status(500).json({ error: err.message });
    }
    res.json(results);
  });
});

app.post('/api/users', (req, res) => {
  const { name, email, role } = req.body;
  db.query('INSERT INTO users (name, email, role) VALUES (?, ?, ?)', [name, email, role], (err, results) => {
    if (err) {
      return res.status(500).json({ error: err.message });
    }
    res.status(201).json({ id: results.insertId, name, email, role });
  });
});

app.put('/api/users/:id', (req, res) => {
  const { id } = req.params;
  const { name, email, role } = req.body;
  db.query('UPDATE users SET name = ?, email = ?, role = ? WHERE id = ?', [name, email, role, id], (err) => {
    if (err) {
      return res.status(500).json({ error: err.message });
    }
    res.status(200).json({ id, name, email, role });
  });
});

app.delete('/api/users/:id', (req, res) => {
  const { id } = req.params;
  db.query('DELETE FROM users WHERE id = ?', [id], (err) => {
    if (err) {
      return res.status(500).json({ error: err.message });
    }
    res.status(200).json({ message: 'User deleted successfully' });
  });
});

// Start server
const server = app.listen(port, () => {
  console.log(`Backend API running on port ${port}`);
});

// Graceful shutdown — handles SIGTERM from K8s and dumb-init
// Without this: SIGTERM → Node exits immediately → in-flight requests dropped
// With this: SIGTERM → stop accepting new connections → finish in-flight → close DB → exit
process.on('SIGTERM', () => {
  console.log('SIGTERM received. Starting graceful shutdown...');
  server.close(() => {
    console.log('HTTP server closed.');
    if (db) {
      db.end(() => {
        console.log('Database connection closed.');
        process.exit(0);
      });
    } else {
      process.exit(0);
    }
  });
  // Force exit after 10s if graceful shutdown hangs
  setTimeout(() => {
    console.error('Graceful shutdown timed out. Forcing exit.');
    process.exit(1);
  }, 10000);
});
