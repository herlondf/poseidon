# Minimal FastAPI contender for the framework comparison: serves the three
# TechEmpower-style endpoints, nothing else - same contract as every other
# contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
# keep-alive). fastapi+uvicorn are resolved from PyPI at image-build time
# (see Dockerfile) - only this file and large.json are committed to the repo.
import pathlib

from fastapi import FastAPI
from fastapi.responses import PlainTextResponse, Response

LARGE_JSON = (pathlib.Path(__file__).parent / "large.json").read_bytes()

app = FastAPI()


@app.get("/plaintext")
def plaintext():
    return PlainTextResponse("Hello, World!")


@app.get("/json")
def json_small():
    return Response(content='{"message":"Hello, World!"}', media_type="application/json")


@app.get("/json-large")
def json_large():
    return Response(content=LARGE_JSON, media_type="application/json")
