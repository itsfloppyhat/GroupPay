FROM python:3.14-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /app
COPY requirements-cloud.txt ./
RUN pip install --no-cache-dir -r requirements-cloud.txt \
    && groupadd --system app && useradd --system --gid app app
COPY server.py storage.py cloud_app.py ./
COPY cloud/gunicorn.conf.py ./gunicorn.conf.py
USER app
CMD ["gunicorn", "--config", "gunicorn.conf.py", "cloud_app:create_app()"]
