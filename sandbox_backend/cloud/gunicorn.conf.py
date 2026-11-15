"""Cloud Run terminates TLS; never enable access logging or request/error dumps."""
import os

bind = "0.0.0.0:" + str(int(os.environ.get("PORT", "8080")))
workers = 1
worker_class = "gthread"
threads = 8
timeout = 130  # Cloud Run stops serving at 120s; durable reconciliation handles uncertain outcomes.
graceful_timeout = 10
keepalive = 5
accesslog = None
errorlog = "/dev/null"
capture_output = False
loglevel = "critical"
limit_request_line = 2048
limit_request_fields = 32
limit_request_field_size = 4096
