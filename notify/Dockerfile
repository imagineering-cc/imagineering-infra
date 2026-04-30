FROM python:3.12-alpine
WORKDIR /app
COPY notify.py /app/
USER nobody
EXPOSE 8090
CMD ["python", "/app/notify.py"]
