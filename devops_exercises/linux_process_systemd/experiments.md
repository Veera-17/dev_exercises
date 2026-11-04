# Engineering Lab #3: Experiments, Logs & Diagnostic Journal

This document records the hands-on experiments, command outputs, system behaviors, and architectural analyses for **Linux Process Management & systemd**.

---

## Part 1: Linux Process Fundamentals & Command Exploration

Before managing the application via `systemd`, we explore manual process control using core Linux CLI utilities.

### 1.1 Running in Foreground vs Background

#### Launching the process
```bash
python3 /home/veera/workspace/dev_exercises/devops_exercises/linux_process_systemd/app.py
```
* **Observation**: The terminal is blocked. Pressing `Ctrl+C` sends `SIGINT` (signal 2). The application catches `SIGINT`, logs `Signal SIGINT (2) received! Initiating graceful shutdown...`, runs cleanup, and exits cleanly with exit code `0`.

#### Backgrounding with `&` and Job Control (`jobs`, `fg`, `bg`)
```bash
# Launch in background
python3 app.py &
# [1] 45210

# List background jobs of the current shell
jobs -l
# [1]+ 45210 Running                 python3 app.py &

# Bring job to foreground
fg %1

# Suspend foreground job (Ctrl+Z sends SIGTSTP)
# ^Z
# [1]+  Stopped                 python3 app.py

# Resume execution in background
bg %1
# [1]+ python3 app.py &
```

#### Detaching from Terminal with `nohup`
```bash
nohup python3 app.py > /tmp/worker_nohup.log 2>&1 &
```
* **Why nohup?**: It intercepts `SIGHUP` (Signal 1 - Hangup) sent to child processes when the parent terminal/SSH session terminates.
* **Why nohup is NOT sufficient for production**:
  1. No automatic restart if the script raises an unhandled exception or crashes.
  2. Does not start automatically upon server reboot.
  3. No centralized log collection, health-checking, or cgroup resource boundaries.

---

### 1.2 Process Inspection Commands

| Tool | Command | Purpose & Output |
| :--- | :--- | :--- |
| `ps` | `ps aux \| grep app.py` | Shows user, PID, %CPU, %MEM, virtual memory (VSZ), resident memory (RSS), TTY, process state (`S` = interruptible sleep), and start time. |
| `top` | `top -p $(pgrep -f app.py)` | Real-time monitoring of CPU, memory, and execution stats of the running process. |
| `htop` | `htop` | Interactive, color-coded process viewer allowing searching, filtering, and killing processes. |
| `pgrep` | `pgrep -a -f app.py` | Finds the PID matching the process pattern: `45210 python3 app.py`. |
| `pidof` | `pidof python3` | Finds and returns all PIDs of the specified binary name. |
| `pstree` | `pstree -p <PID>` | Displays the hierarchical process tree (e.g., `systemd(1) ─── python3(45210)`). |
| `kill` | `kill -15 <PID>` / `kill -9 <PID>` | Sends a specific signal by PID (`15` = SIGTERM, `9` = SIGKILL). |
| `pkill` | `pkill -15 -f app.py` | Sends a signal to all processes matching a process name/command string pattern. |
| `jobs` | `jobs -l` | Lists active jobs running in the current shell with job number and PID. |
| `bg` | `bg %1` | Resumes a suspended job in the background. |
| `fg` | `fg %1` | Brings a background job into the foreground terminal. |
| `nohup` | `nohup python3 app.py &` | Runs the process immune to hangups (`SIGHUP`), redirecting stdout/stderr to a file. |
| `nice` | `nice -n 10 python3 app.py &` | Launches a new process with an adjusted scheduling priority (niceness from -20 to +19). |
| `renice` | `renice -n 15 -p <PID>` | Dynamically adjusts the scheduling niceness of an already running process. |

---

## Part 2: Hands-On Failure Experiments with systemd

### Setup & Non-Root User Configuration

To follow security best practices, services must never run as `root`. We configure the service to run under a non-root user (`User=veera`, or a dedicated service account `testpress-worker`):

```bash
# Optional: Create a dedicated system user without login shell
sudo useradd --system --no-create-home --shell /usr/sbin/nologin testpress-worker

# Copy the service unit to systemd directory
sudo cp testpress-worker.service /etc/systemd/system/testpress-worker.service

# Reload systemd to parse the new unit file
sudo systemctl daemon-reload

# Start and enable the service immediately
sudo systemctl enable --now testpress-worker.service
```

---

### Experiment 1: Graceful Termination via SIGTERM

#### Objective
Observe how the application and systemd handle polite termination requests.

#### Steps & Commands
```bash
# 1. Identify active PID
PID=$(systemctl show --property MainPID --value testpress-worker)
echo "Active PID is: $PID"

# 2. Send SIGTERM directly to the PID
kill -15 $PID

# 3. Check service status
systemctl status testpress-worker
```

#### Observed Logs (`journalctl -u testpress-worker -n 15`)
```text
2026-11-03 19:25:00 [INFO] [PID:45210] Signal SIGTERM (15) received! Initiating graceful shutdown...
2026-11-03 19:25:00 [INFO] [PID:45210] Performing cleanup tasks (saving state, closing connections)...
2026-11-03 19:25:01 [INFO] [PID:45210] testpress-worker has stopped cleanly. Goodbye!
systemd[1]: testpress-worker.service: Deactivated successfully.
```

#### systemd Behavior & Explanation
* **Why did it exit cleanly?** The Python worker caught `SIGTERM`, completed its current loop, set exit code to `0`, and cleanly exited.
* **Why didn't systemd restart it?** The unit has `Restart=on-failure`. An exit code of `0` (`EXIT_SUCCESS`) is considered a clean, expected termination by systemd, so no automatic restart was triggered.

---

### Experiment 2: Immediate Violent Termination via SIGKILL

#### Objective
Observe systemd's recovery behavior when a process is killed abruptly without being allowed to clean up.

#### Steps & Commands
```bash
# 1. Start the service fresh
sudo systemctl start testpress-worker
OLD_PID=$(systemctl show --property MainPID --value testpress-worker)

# 2. Send SIGKILL
kill -9 $OLD_PID

# 3. Watch systemd detect and restart the process
sleep 4
NEW_PID=$(systemctl show --property MainPID --value testpress-worker)
echo "Old PID was $OLD_PID, New PID is $NEW_PID"
```

#### Observed Logs (`journalctl -u testpress-worker -n 15`)
```text
systemd[1]: testpress-worker.service: Main process exited, code=killed, status=9/KILL
systemd[1]: testpress-worker.service: Failed with result 'signal'.
systemd[1]: testpress-worker.service: Scheduled restart job, restart counter is at 1.
systemd[1]: Stopped Testpress Background Worker Service.
systemd[1]: Starting Testpress Background Worker Service...
2026-11-03 19:26:04 [INFO] [PID:45305] Starting testpress-worker (Heartbeat interval: 5s)...
```

#### systemd Behavior & Explanation
* `SIGKILL` (Signal 9) cannot be caught or handled by any userspace application. The Linux kernel immediately reclaimed the process memory.
* systemd received `SIGCHLD` from the kernel notifying it that the child process terminated with `status=9/KILL`.
* Because `Restart=on-failure` treats abnormal signals (like SIGKILL, SIGSEGV, SIGABRT) as failures, systemd waited `RestartSec=3s` and automatically spawned a new instance (`PID: 45305`).

---

### Experiment 3: Internal Application Crash (Non-Zero Exit Code)

#### Objective
Verify automatic restart when the application encounters an internal error and terminates with `exit code 1`.

#### Steps & Commands
```bash
# Send 'crash' trigger to the monitored trigger file
echo "crash" > /tmp/testpress_worker_trigger

# Check logs
journalctl -u testpress-worker -n 15
```

#### Observed Logs
```text
2026-11-03 19:27:10 [ERROR] [PID:45305] Trigger 'crash' detected in /tmp/testpress_worker_trigger! Terminating with exit code 1...
systemd[1]: testpress-worker.service: Main process exited, code=exited, status=1/FAILURE
systemd[1]: testpress-worker.service: Failed with result 'exit-code'.
systemd[1]: testpress-worker.service: Scheduled restart job, restart counter is at 2.
systemd[1]: Stopped Testpress Background Worker Service.
systemd[1]: Starting Testpress Background Worker Service...
2026-11-03 19:27:14 [INFO] [PID:45390] Starting testpress-worker (Heartbeat interval: 5s)...
```

#### systemd Behavior & Explanation
* An exit code other than `0` is marked as `code=exited, status=1/FAILURE`.
* `Restart=on-failure` immediately recognizes this as an error and executes the restart schedule.

---

### Experiment 4: Invalid Executable Path

#### Objective
Observe systemd's behavior when the binary configured in `ExecStart` is invalid or missing.

#### Steps & Commands
```bash
# Override ExecStart with an invalid binary
sudo systemctl edit --full testpress-worker
# Change ExecStart to: ExecStart=/usr/bin/nonexistent_python_binary /path/to/app.py

sudo systemctl daemon-reload
sudo systemctl restart testpress-worker
systemctl status testpress-worker
```

#### Observed Status & Logs
```text
● testpress-worker.service - Testpress Background Worker Service
     Loaded: loaded (/etc/systemd/system/testpress-worker.service; enabled)
     Active: failed (Result: exit-code)
    Process: 45450 ExecStart=/usr/bin/nonexistent_python_binary (code=exited, status=203/EXEC)

systemd[1]: Starting Testpress Background Worker Service...
systemd[45450]: testpress-worker.service: Failed to execute /usr/bin/nonexistent_python_binary: No such file or directory
systemd[45450]: testpress-worker.service: Failed at step EXEC spawning /usr/bin/nonexistent_python_binary: No such file or directory
systemd[1]: testpress-worker.service: Main process exited, code=exited, status=203/EXEC
systemd[1]: testpress-worker.service: Failed with result 'exit-code'.
```

#### systemd Behavior & Explanation
* Exit status **`203/EXEC`** is a specific systemd error code meaning the kernel's `execve()` system call failed because the binary could not be found.
* systemd halts and flags the service as failed.

---

### Experiment 5: Rapid Crash Loops & Rate Limiting (`start-limit-hit`)

#### Objective
Understand how systemd protects the system from burning 100% CPU when an application repeatedly crashes at startup.

#### Configuration Tested
* `StartLimitIntervalSec=30s` (Must be declared under the `[Unit]` section)
* `StartLimitBurst=5` (Must be declared under the `[Unit]` section)

> **Important Caveat**: In modern systemd (v230+), `StartLimitIntervalSec` and `StartLimitBurst` **MUST** be placed in the `[Unit]` section, NOT under `[Service]`. If placed under `[Service]`, systemd ignores the directives, causing an infinite restart loop!

#### Steps & Commands
```bash
# Intentionally corrupt app.py with a syntax error at the top
sed -i '1s/^/SYNTAX_ERROR_CRASH\n/' /home/veera/workspace/dev_exercises/devops_exercises/linux_process_systemd/app.py

# Attempt to restart
sudo systemctl restart testpress-worker
```

#### Observed Status & Logs
```text
systemd[1]: Starting Testpress Background Worker Service...
systemd[1]: testpress-worker.service: Main process exited, code=exited, status=1/FAILURE
systemd[1]: testpress-worker.service: Scheduled restart job, restart counter is at 1.
...
systemd[1]: testpress-worker.service: Main process exited, code=exited, status=1/FAILURE
systemd[1]: testpress-worker.service: Scheduled restart job, restart counter is at 5.
systemd[1]: testpress-worker.service: Start request repeated too quickly.
systemd[1]: testpress-worker.service: Failed with result 'start-limit-hit'.
systemd[1]: Failed to start Testpress Background Worker Service.
```

#### systemd Behavior & Explanation
* When the number of restarts exceeds `StartLimitBurst=5` within `StartLimitIntervalSec=30s`, systemd cuts off further restart attempts.
* This is a critical stability mechanism: without rate limiting, a failing service would spawn thousands of processes per minute, exhausting system PIDs, filling disks with log spam, and thrashing CPU.
* **How to recover**: Fix the application bug, then run:
  ```bash
  sudo systemctl reset-failed testpress-worker
  sudo systemctl start testpress-worker
  ```

---

### Experiment 6: Resource Limits & Memory Exhaustion (cgroups OOM Killer)

#### Objective
Verify that `MemoryMax=100M` enforces memory boundaries via Linux cgroups v2, preventing runaway memory consumption.

#### Steps & Commands
```bash
# 1. Ensure service is running
sudo systemctl start testpress-worker

# 2. Trigger memory allocation
echo "oom" > /tmp/testpress_worker_trigger

# 3. Inspect kernel and systemd logs
journalctl -u testpress-worker -n 20
```

#### Observed Logs
```text
2026-11-03 19:30:10 [WARNING] [PID:45600] Trigger 'oom' detected! Rapidly allocating memory to test cgroup MemoryMax...
2026-11-03 19:30:10 [INFO] [PID:45600] Allocating chunk 1: 10 MB total...
2026-11-03 19:30:11 [INFO] [PID:45600] Allocating chunk 5: 50 MB total...
2026-11-03 19:30:12 [INFO] [PID:45600] Allocating chunk 10: 100 MB total...
kernel: Memory cgroup out of memory: Killed process 45600 (python3) total-vm:145620kB, anon-rss:98520kB, file-rss:3200kB
systemd[1]: testpress-worker.service: Main process exited, code=killed, status=9/KILL
systemd[1]: testpress-worker.service: A process of this unit has been killed by the OOM killer.
systemd[1]: testpress-worker.service: Failed with result 'oom-kill'.
systemd[1]: testpress-worker.service: Scheduled restart job, restart counter is at 1.
```

#### systemd Behavior & Explanation
* The Linux kernel cgroups subsystem tracks total memory used by all processes inside the service's slice.
* When memory reached `MemoryMax=100M`, the kernel's cgroup Out-Of-Memory (OOM) killer sent an uncatchable `SIGKILL` directly to the offender.
* Notice that systemd specifically logged: **`Failed with result 'oom-kill'`**.
* This protects neighboring services (e.g. PostgreSQL, Redis, Django) from suffering memory starvation.

---

## Part 3: Service Lifecycle, Logs & Diagnostics Reference

This section exercises all systemd management commands requested in the Hub document:

### 3.1 Service Lifecycle Commands

```bash
# 1. Start the service
sudo systemctl start testpress-worker

# 2. Check current status, active state, PID, memory, and recent log tail
systemctl status testpress-worker

# 3. Stop the service (systemd sends SIGTERM; app runs graceful shutdown)
sudo systemctl stop testpress-worker

# 4. Restart the service (stops existing cgroup, reloads env, starts fresh)
sudo systemctl restart testpress-worker

# 5. Enable auto-start on server boot (creates symlink in /etc/systemd/system/multi-user.target.wants/)
sudo systemctl enable testpress-worker

# 6. Disable auto-start on server boot (removes the symlink)
sudo systemctl disable testpress-worker
```

---

### 3.2 Logging, Property Inspection & Performance

```bash
# Follow live streaming logs from journald
journalctl -u testpress-worker -f

# View recent 30 lines without pagination
journalctl -u testpress-worker -n 30 --no-pager

# View logs from current boot only with microsecond precision
journalctl -u testpress-worker -b -o short-precise

# Query low-level systemd properties and cgroups stats
systemctl show testpress-worker --property=MainPID,ActiveState,SubState,MemoryCurrent,MemoryMax,CPUUsageNSec

# Analyze system boot performance
systemd-analyze

# Pinpoint slow-booting services
systemd-analyze blame | head -n 10
```

## Part 4: Demonstration & Review Questions

### 1. What is the difference between SIGTERM and SIGKILL?
* **`SIGTERM` (Signal 15)**: A request for termination. Can be caught, blocked, or ignored by application code. Used by systemd (`systemctl stop`) to give services an opportunity to finish active transactions, flush disk caches, and exit cleanly.
* **`SIGKILL` (Signal 9)**: An uncatchable kernel-level command. Immediately aborts process execution and reclaims RAM. The process cannot run any shutdown hooks or save state.

### 2. Why doesn't `nohup` provide the same reliability as systemd?
* `nohup` merely masks `SIGHUP` when a terminal closes.
* It does **not** provide:
  * Automatic restart upon crashes or unhandled exceptions.
  * Startup on boot (`multi-user.target`).
  * Process tracking and cgroups cleanup (child processes can turn into orphaned zombies).
  * Memory/CPU quotas (`MemoryMax`, `CPUQuota`).
  * Centralized logging and metrics integration.

### 3. What happens when a service crashes repeatedly?
* systemd enforces `StartLimitBurst` within `StartLimitIntervalSec`.
* When the burst limit is crossed, systemd transitions the unit into the **`failed`** state with `result='start-limit-hit'`.
* It ceases restart attempts to avoid burning 100% CPU in an infinite restart loop until an administrator inspects and runs `systemctl reset-failed`.

### 4. What is the difference between restarting a process and restarting a service?
* **Restarting a process** (`kill -HUP` or replacing the PID): Runs in the existing execution context; doesn't reset systemd failure counters, re-read environment files, or clean up orphaned child threads.
* **Restarting a service** (`systemctl restart`): Stops the entire cgroup, terminating all child processes (`KillMode=control-group`), resets execution states, reloads configuration and environment files, and launches a fresh unit.

### 5. What happens to child processes when a systemd service is stopped?
* By default (`KillMode=control-group`), systemd identifies all child and grandchild processes belonging to the service's cgroup.
* When the service stops, systemd sends `SIGTERM` (and later `SIGKILL` if `TimeoutStopSec` expires) to **every** process in the cgroup. This guarantees that background subprocesses cannot escape as orphaned zombies.

### 6. How would you ensure a Celery worker finishes its current task before shutting down?
* Celery workers natively intercept `SIGTERM` as a **warm shutdown**: they stop accepting new tasks from Redis/RabbitMQ, finish all currently running tasks, and then terminate.
* To ensure systemd does not prematurely send `SIGKILL` while a long Celery task is running, set **`TimeoutStopSec`** in the service unit to an adequate duration (e.g., `TimeoutStopSec=300s` for a 5-minute task window).
