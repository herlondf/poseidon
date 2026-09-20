# express is resolved from npm's registry at build time via package.json -
# nothing framework-related is vendored into this repo, only server.js/large.json.
FROM node:22-slim
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js large.json ./
EXPOSE 8080
CMD ["node", "server.js"]
