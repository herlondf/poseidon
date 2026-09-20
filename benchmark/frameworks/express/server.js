// Minimal Express contender for the framework comparison: serves the three
// TechEmpower-style endpoints, nothing else - same contract as every other
// contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
// keep-alive). express is npm's most-used HTTP framework, downloaded fresh
// from the registry at image-build time (see Dockerfile) - only this file
// and package.json are committed to the repo.
const fs = require('fs');
const path = require('path');
const express = require('express');

const largeJson = fs.readFileSync(path.join(__dirname, 'large.json'));

const app = express();
app.disable('x-powered-by');

app.get('/plaintext', (req, res) => {
  res.type('text/plain').send('Hello, World!');
});

app.get('/json', (req, res) => {
  res.type('application/json').send('{"message":"Hello, World!"}');
});

app.get('/json-large', (req, res) => {
  res.type('application/json').send(largeJson);
});

app.listen(8080, '0.0.0.0');
