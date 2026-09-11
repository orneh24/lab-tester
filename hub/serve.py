#!/usr/bin/env python3
"""Production entrypoint for the lab-tester hub.

Reads HUB_PORT at runtime, so changing it in hub.env actually takes effect
(OpenRC expands command_args at parse time, before the env file is loaded).

Serves through waitress when available. Flask's built-in server is a
development server: single-threaded, so simultaneous result pushes from the
whole mesh would queue behind one another. It remains as a fallback only.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app.app import app  # noqa: E402
from app import config  # noqa: E402
from app import syslog_server  # noqa: E402


def main():
    host = os.environ.get("HUB_HOST", "0.0.0.0")
    port = config.PORT

    # Started here rather than at import time: importing app.app creates the
    # schema the listener writes into, and under the Flask reloader the module
    # is imported twice. start() is idempotent and returns quietly if it cannot
    # bind — an unavailable syslog port must not stop the hub serving results,
    # which is the job that matters.
    syslog_server.start()

    try:
        from waitress import serve
    except ImportError:
        sys.stderr.write(
            "waitress not installed; falling back to the Flask development "
            "server (single-threaded, not recommended)\n"
        )
        app.run(host=host, port=port, threaded=True)
        return

    sys.stderr.write(f"lab-tester hub listening on {host}:{port}\n")
    serve(app, host=host, port=port, threads=8)


if __name__ == "__main__":
    main()
