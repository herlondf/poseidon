# Minimal Django contender for the framework comparison: serves the three
# TechEmpower-style endpoints, nothing else - same contract as every other
# contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
# keep-alive). This file is copied into a Django project skeleton generated
# fresh at image-build time by `django-admin startproject` (see Dockerfile) -
# only this file, urls.py and large.json are committed to the repo.
import pathlib

from django.http import HttpResponse

LARGE_JSON = (pathlib.Path(__file__).parent / "large.json").read_bytes()


def plaintext(request):
    return HttpResponse("Hello, World!", content_type="text/plain")


def json_small(request):
    return HttpResponse('{"message":"Hello, World!"}', content_type="application/json")


def json_large(request):
    return HttpResponse(LARGE_JSON, content_type="application/json")
