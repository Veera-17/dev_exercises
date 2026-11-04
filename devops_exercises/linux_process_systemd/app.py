#!/usr/bin/env python3
"""
Testpress Engineering Lab #3: Linux Process Management & systemd
Background Worker Application (app.py)

Features:
- Continuous heartbeat logging (every 5s, configurable).
- Graceful handling of SIGTERM and SIGINT (graceful exit with code 0).
- Configurable via environment variables.
- Trigger mechanism to simulate crashes (exit 1), exceptions, and memory exhaustion (OOM).
"""

import os
import sys
import time
import signal
import logging

# Configure logging format to standard output (captured by systemd journald)
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s [%(levelname)s] [PID:%(process)d] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    stream=sys.stdout
)


class TestpressWorker:
    def __init__(self):
        self.running = True
        self.worker_name = os.getenv("WORKER_NAME", "testpress-worker")
        self.interval = int(os.getenv("HEARTBEAT_INTERVAL", "5"))
        self.trigger_file = os.getenv("TRIGGER_FILE", "/tmp/testpress_worker_trigger")
        self.heartbeat_count = 0

        self._setup_signal_handlers()

    def _setup_signal_handlers(self):
        """Register signal handlers for graceful shutdown."""
        signal.signal(signal.SIGTERM, self._handle_termination)
        signal.signal(signal.SIGINT, self._handle_termination)
        # Bonus: allow SIGUSR1 to simulate a quick crash
        signal.signal(signal.SIGUSR1, self._handle_crash_signal)

    def _handle_termination(self, signum, frame):
        sig_name = signal.Signals(signum).name
        logging.info(f"Signal {sig_name} ({signum}) received! Initiating graceful shutdown...")
        # Setting running to False allows current loop iteration to finish
        self.running = False

    def _handle_crash_signal(self, signum, frame):
        logging.error("SIGUSR1 received! Simulating sudden unhandled application failure...")
        sys.exit(1)

    def check_triggers(self):
        """
        Check trigger file to simulate failures dynamically during experiments:
        - 'crash': exits with non-zero code 1
        - 'exception': raises unhandled Python exception
        - 'oom': rapidly allocates memory to exceed cgroup MemoryMax limit
        """
        if not os.path.exists(self.trigger_file):
            return

        try:
            with open(self.trigger_file, "r") as f:
                command = f.read().strip().lower()
        except Exception as e:
            logging.warning(f"Failed to read trigger file: {e}")
            return

        if command == "crash":
            logging.error("Trigger 'crash' detected in %s! Terminating with exit code 1...", self.trigger_file)
            try:
                os.remove(self.trigger_file)
            except OSError:
                pass
            sys.exit(1)

        elif command == "exception":
            logging.error("Trigger 'exception' detected! Raising unhandled RuntimeError...")
            try:
                os.remove(self.trigger_file)
            except OSError:
                pass
            raise RuntimeError("Simulated unhandled exception triggered by experiment.")

        elif command == "oom":
            logging.warning("Trigger 'oom' detected! Rapidly allocating memory to test cgroup MemoryMax...")
            try:
                os.remove(self.trigger_file)
            except OSError:
                pass
            # Allocate 10MB chunks repeatedly until OS kernel / cgroup kills the process
            memory_sink = []
            chunk_size = 10 * 1024 * 1024  # 10MB
            for i in range(1, 100):
                logging.info(f"Allocating chunk {i}: {i * 10} MB total...")
                memory_sink.append(bytearray(chunk_size))
                time.sleep(0.1)

    def run(self):
        logging.info("Starting %s (Heartbeat interval: %ds)...", self.worker_name, self.interval)
        logging.info("Trigger file monitored at: %s", self.trigger_file)

        while self.running:
            self.heartbeat_count += 1
            self.check_triggers()
            logging.info("[%s] Heartbeat #%d: Service healthy and operating normally.",
                         self.worker_name, self.heartbeat_count)

            # Sleep in 1-second increments so signals are handled responsively
            for _ in range(self.interval):
                if not self.running:
                    break
                time.sleep(1)

        # Graceful cleanup section
        logging.info("Performing cleanup tasks (saving state, closing connections)...")
        time.sleep(0.5)  # Simulate clean resource teardown
        logging.info("%s has stopped cleanly. Goodbye!", self.worker_name)
        sys.exit(0)


if __name__ == "__main__":
    worker = TestpressWorker()
    worker.run()
