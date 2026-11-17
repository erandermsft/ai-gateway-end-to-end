# MCR base image avoids Docker Hub pull limits during ACR remote builds.
ARG BASE_IMAGE=mcr.microsoft.com/azurelinux/base/python:3.12
FROM ${BASE_IMAGE}

# Optional private package index, e.g. --build-arg PYPI_INDEX_URL=https://my-mirror/simple
ARG PYPI_INDEX_URL=

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    HOME=/tmp \
    PORT=8000

WORKDIR /app
COPY requirements.txt .
RUN python3 -m pip install --break-system-packages ${PYPI_INDEX_URL:+--index-url "$PYPI_INDEX_URL"} -r requirements.txt

COPY server.py .

USER 10001
EXPOSE 8000
CMD ["python3", "server.py"]
