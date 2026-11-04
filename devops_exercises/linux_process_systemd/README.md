# Engineering Lab #3: Linux Process Management & systemd

A hands-on exercise exploring how Linux manages background processes, handles signals, and automatically recovers crashed services using systemd.

---

## 📁 Files in this Directory

* **`app.py`**: The Python worker that prints a heartbeat every 5s and catches shutdown signals.
* **`testpress-worker.service`**: The systemd configuration telling Linux how to run, supervise, and auto-restart `app.py`.
* **`testpress-worker.env`**: Environment file containing settings (heartbeat interval, log level, etc.).
* **`experiments.md`**: Step-by-step logs of what happens when we crash, kill, or exhaust memory on the service.

---

## 🚀 Setup & Installation (One-time)

To register this service with Linux systemd:

```bash
# 1. (Optional) Create a dedicated non-root system user (or use your existing user)
# sudo useradd --system --no-create-home --shell /usr/sbin/nologin testpress-worker

# 2. Make the Python script executable
chmod +x /home/veera/workspace/dev_exercises/devops_exercises/linux_process_systemd/app.py

# 3. Copy the service configuration to where Linux looks for services
sudo cp /home/veera/workspace/dev_exercises/devops_exercises/linux_process_systemd/testpress-worker.service /etc/systemd/system/

# 4. Tell systemd to read the new file
sudo systemctl daemon-reload

# 5. Start the service now and enable it to start on system boot
sudo systemctl enable --now testpress-worker.service

# 6. Check if it is running
systemctl status testpress-worker.service
```

---

## 🔍 How to View Live Logs

```bash
journalctl -u testpress-worker -f
```

---

## 🧪 Quick Experiment Triggers

| What to test | Command | What will happen |
| :--- | :--- | :--- |
| **Graceful Stop** | `kill -15 <PID>` | Worker catches `SIGTERM`, finishes current loop, and exits cleanly (exit code 0). |
| **Forced Kill** | `kill -9 <PID>` | Kernel kills the process instantly. systemd notices it died, waits 3s, and starts a new one. |
| **Simulated Crash** | `echo crash > /tmp/testpress_worker_trigger` | App exits with error code 1. systemd auto-restarts it. |
| **Simulated OOM** | `echo oom > /tmp/testpress_worker_trigger` | App exceeds 100MB RAM limit. Linux kernel OOM-killer stops it. |
