# nginx as the "hardware ceiling" reference: a static-string HTTP responder with
# no application logic. Not an app framework — the upper bound the app frameworks
# are measured against.
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/nginx.conf
COPY large.json /usr/share/nginx/html/large.json
EXPOSE 8080
