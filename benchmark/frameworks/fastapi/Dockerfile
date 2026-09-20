# fastapi + uvicorn are resolved from PyPI at build time - nothing
# framework-related is vendored into this repo, only main.py/large.json.
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir fastapi==0.115.* "uvicorn[standard]==0.32.*"
COPY main.py large.json ./
EXPOSE 8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
