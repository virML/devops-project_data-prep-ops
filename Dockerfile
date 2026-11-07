# Same small Python image is used as the API and background SQS worker.
FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /opt/dataprepops
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && \
    groupadd -g 10001 dpops && useradd -u 10001 -g dpops -M dpops
COPY --chown=10001:10001 app.py cleaner.py worker.py ./
USER 10001:10001
EXPOSE 8082
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8082"]
