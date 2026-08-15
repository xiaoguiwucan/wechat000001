FROM docker.m.daocloud.io/library/python:3.12-slim
WORKDIR /app
COPY app.py /app/app.py
COPY static /app/static
ENV WECHAT_INGEST_ROOT=/data
ENV CONSOLE_PORT=18791
EXPOSE 18791
CMD ["python3", "-u", "/app/app.py"]
