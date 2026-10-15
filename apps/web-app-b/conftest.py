"""Test bootstrap for web-app-b.

app.py reads required Redis settings and builds its client at import time, so
the environment must be populated before the module is first imported.
Redis.__init__ does not open a connection, so no server is needed.
"""
import os

os.environ["REDIS_HOST"] = "redis.test"
os.environ["REDIS_PASSWORD"] = "test-password"
os.environ.pop("REDIS_CERT_B64", None)
os.environ.pop("REDIS_USERNAME", None)
