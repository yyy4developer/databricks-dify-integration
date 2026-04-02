FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -i https://pypi-proxy.dev.databricks.com/simple -r requirements.txt
COPY app.py .
CMD ["python", "app.py"]
