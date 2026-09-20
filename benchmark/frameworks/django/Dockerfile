# django + gunicorn are resolved from PyPI at build time, and the project
# skeleton itself is generated fresh by `django-admin startproject` - nothing
# framework-related is vendored into this repo, only views.py/urls.py/large.json,
# copied into the generated project to wire up the three endpoints.
FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir django==5.1.* gunicorn==23.*
RUN django-admin startproject benchproj .
RUN echo "ALLOWED_HOSTS = ['*']" >> benchproj/settings.py
COPY urls.py views.py large.json benchproj/
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "benchproj.wsgi:application"]
