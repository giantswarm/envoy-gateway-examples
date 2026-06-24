FROM python:3.14-slim

WORKDIR /app

RUN pip install --no-cache-dir flask==3.0.3

COPY app.py /app/app.py

ENV PORT=8000
EXPOSE 8000

CMD ["python", "/app/app.py"]
