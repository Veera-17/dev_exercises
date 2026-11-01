# DevOps Exercise: Bonus Challenges & Deep-Dive Learnings

This document provides complete, thorough answers and technical investigations for all **Bonus Challenges** outlined in the [Automated Server Provisioning with Cloud-Init](https://hub.testpress.tech/doc/automated-server-provisioning-with-cloud-init-tCyEvj0m4f) exercise.

---

## 1. Configure a systemd service to manage the Dockerized application

### Implementation Status: ✅ Fully Implemented & Verified

In our `cloud-init.yaml`, we created a dedicated systemd unit at `/etc/systemd/system/testpress-app.service`:

```ini
[Unit]
Description=Testpress Demo HTTP Application
After=docker.service
Requires=docker.service

[Service]
TimeoutStartSec=0
Restart=always
ExecStartPre=-/usr/bin/docker stop testpress-demo
ExecStartPre=-/usr/bin/docker rm testpress-demo
ExecStartPre=/usr/bin/docker pull hashicorp/http-echo:latest
ExecStart=/usr/bin/docker run --name testpress-demo \
  --env-file /opt/testpress/app.env \
  -p 8080:5678 \
  hashicorp/http-echo:latest -text "Hello from Testpress!"
ExecStop=/usr/bin/docker stop testpress-demo

[Install]
WantedBy=multi-user.target
```

### Why this is production-grade:
1. **Lifecycle Management**: The OS init system (`systemd`) treats the container like any first-class daemon (such as Nginx or PostgreSQL).
2. **Crash Resilience**: `Restart=always` ensures that if the container process is killed (e.g., out-of-memory or manually via `docker kill`), systemd re-spawns it immediately.
3. **Boot Ordering**: `After=docker.service Requires=docker.service` guarantees systemd will never attempt to launch the container before the Docker engine is fully initialized.

---

## 2. Implement a Health Check for the Application

### Implementation Status: ✅ Tested & Documented

There are two distinct ways to implement health checks:

### Method A: Host-Level Health Check (Systemd Watchdog / Verification Script)
Because minimal images (like `hashicorp/http-echo`) are built on scratch without `curl` or `nc` binaries inside the container, running health checks from the host using `curl` against port `8080` is the most reliable:

```bash
# Verify health from the host:
multipass exec testpress-vm -- curl -f -s -o /dev/null http://localhost:8080; echo "HEALTHY"
```

### Method B: Docker Container Health Check
If using an application container that includes `curl` or `wget` (e.g. Python, Nginx, or Node):
```bash
docker run -d --name testpress-demo \
  --health-cmd="curl -f http://localhost:8080/ || exit 1" \
  --health-interval=10s \
  --health-timeout=3s \
  --health-retries=3 \
  -p 8080:8080 my-app-image
```
Docker tracks health status in `docker inspect --format='{{.State.Health.Status}}' testpress-demo`.

---

## 3. How Cloud-Init Determines Whether a VM is Booting for the First Time

### Implementation Status: ✅ Investigated with Live VM Proof

Cloud-init determines whether an instance is booting for the first time using an **Instance ID & Semaphore Tracking Mechanism**:

1. **Datasource Detection & Instance ID**:
   - During early boot (`cloud-init-local` stage), cloud-init reads the machine's `instance-id` from the metadata source (e.g., from `/dev/sr0` in Multipass, or `169.254.169.254` on AWS).
2. **Instance Cache Inspection**:
   - Cloud-init checks `/var/lib/cloud/instance/obj.pkl`.
   - If `/var/lib/cloud/instance/` does not exist or points to a different `instance-id`, cloud-init declares this boot a **First Boot (New Instance)**.
3. **Semaphore Markers (`sem/`)**:
   - For modules marked with frequency `once-per-instance` (such as `users-groups`, `write_files`, and `runcmd`), cloud-init creates a lock file in `/var/lib/cloud/instances/<instance-id>/sem/`.
   - Once all modules finish, cloud-init writes the completion sentinel:
     `/var/lib/cloud/instance/boot-finished`
4. **On Subsequent Boots (Reboots)**:
   - Cloud-init detects that `instance-id` has not changed and that `boot-finished` exists.
   - It skips all `once-per-instance` modules, preserving performance and ensuring idempotency.

You can verify this inside your running VM:
```bash
multipass exec testpress-vm -- bash -c "ls -la /var/lib/cloud/instances/*/sem/"
multipass exec testpress-vm -- cat /var/lib/cloud/instance/boot-finished
```

---

## 4. Difference Between Cloud-Init and a Dockerfile

| Feature / Dimension | Cloud-Init | Dockerfile |
| :--- | :--- | :--- |
| **Primary Scope** | **Virtual Machine / OS Level** provisioning. | **Application Container Image** building. |
| **Execution Time** | Runs **at runtime on boot** of a fresh VM. | Runs **at build time** (`docker build`) on a developer machine or CI/CD pipeline. |
| **Target Environment** | Manages the entire Linux OS (kernel parameters, disk partitions, users, SSH keys, network, systemd). | Manages an isolated filesystem namespace inside a container (application code, dependencies, environment). |
| **Output** | A configured, running **server instance**. | A portable, immutable **Docker Image**. |
| **Idempotency** | Handles machine lifecycle across reboots and instance state. | Creates immutable image layers cached during build. |
| **Relationship** | Cloud-init prepares the host server so it can run Docker; Docker runs the application containers on that server. |

---

## 5. How Cloud-Init Receives Configuration Through User-Data and Metadata

### Implementation Status: ✅ Investigated with Live VM Proof

Cloud-init separates configuration into two distinct layers:

### 1. Metadata (`meta-data`)
* **What it is**: Information about the **identity and infrastructure** of the machine.
* **Who provides it**: The hypervisor or cloud platform (AWS, GCP, Multipass, OpenStack).
* **Contents**:
  - `instance-id`: Unique identifier for the instance.
  - `local-hostname`: The hostname assigned to the VM.
  - Public/private IP addresses and availability zone.
* In Multipass, you can view the injected metadata:
  ```bash
  multipass exec testpress-vm -- cloud-init query ds.meta_data
  ```

### 2. User-Data (`user-data`)
* **What it is**: Configuration defined by the **developer/administrator** to customize what software runs on the machine.
* **Who provides it**: You (the person provisioning the server).
* **Contents**: The `#cloud-config` YAML file containing packages, users, environment variables, systemd services, and `runcmd` scripts.
* In Multipass, you can view the cached user-data:
  ```bash
  multipass exec testpress-vm -- sudo cat /var/lib/cloud/instance/user-data.txt
  ```

### How Cloud-Init Fetches Them (Datasources)
1. **Local Hypervisors (Multipass / QEMU - NoCloud)**:
   - Injected via a virtual read-only drive (CD-ROM/drive at `/dev/sr0` or `/dev/vdb`) labeled `CIDATA`.
2. **Public Clouds (AWS EC2 / GCP / Azure)**:
   - Fetched over HTTP from the link-local metadata service at `http://169.254.169.254/latest/user-data`.
