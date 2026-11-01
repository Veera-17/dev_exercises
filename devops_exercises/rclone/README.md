# DevOps Hands-on Exercise: File Transfers & Storage Automation with Rclone

This repository contains the complete implementation, automation scripts, test harnesses, benchmark results, and conceptual answers for the Testpress & TPStreams Rclone DevOps learning exercise.

---

## Table of Contents
1. [Overview & Architecture](#1-overview--architecture)
2. [Prerequisites & Environment Setup](#2-prerequisites--environment-setup)
3. [File Structure & Deliverables](#3-file-structure--deliverables)
4. [Reproduction & Automation Guide (`transfer.sh`)](#4-reproduction--automation-guide-transfersh)
5. [Documentation Index](#5-documentation-index)
6. [Answers to Demonstration & Evaluation Questions](#6-answers-to-demonstration--evaluation-questions)

---

## 1. Overview & Architecture

Large educational assets (video lessons, assessment PDFs, tenant backups, media uploads) require reliable, resilient, and automatable file transfers between local filesystems and S3-compatible object stores (MinIO, AWS S3, Wasabi).

This project demonstrates:
- **Zero Configuration-File Dependency:** Operating Rclone in production without creating or maintaining static `rclone.conf` files.
- **Data Safety:** Understanding exact operational differences between `copy`, `move`, and `sync` to eliminate catastrophic data loss.
- **Transfer Reliability:** Bandwidth throttling (`--bwlimit`), concurrency controls, multipart chunk handling, and automatic retries.
- **Production Automation:** A self-contained, logged Bash script (`transfer.sh`) with strict exit codes for CI/CD and Celery tasks.

---

## 2. Prerequisites & Environment Setup

### Prerequisites
- Linux / WSL environment.
- `rclone` (v1.50+). Verify with:
  ```bash
  rclone --version
  ```
- Local MinIO S3-compatible object storage service listening on `http://localhost:9000` (or via Docker Compose).

### Environment Configuration (`.env`)
The exercise enforces configuration-free execution using environment variables. Prepare your local configuration:
```bash
cd devops_exercises/rclone
cp .env.example .env
```
Default configuration values in `.env`:
- **`MINIO_ENDPOINT_URL`**: `http://localhost:9000`
- **`MINIO_ACCESS_KEY_ID`**: `vr9qAMnUPHUZyP9JRIj3`
- **`MINIO_SECRET_ACCESS_KEY`**: `q5zDZBP0wQSx0nfggomVNamnJhMz1AFouOTyQLDE`
- **`MINIO_HOST_PORT`**: `9000`
- **`MINIO_HOST_CONSOLE_PORT`**: `9001`

*(If MinIO is not already installed locally, launch it with Docker: `docker compose up -d`)*


## 3. Reproduction & Automation Guide (`transfer.sh`)

`transfer.sh` is the unified automation script for local and S3 operations. It automatically injects credentials from `.env` in-memory (`--config=/dev/null`), streams real-time progress (`-P`), logs to `transfer.log`, and returns exit codes.

### Step 1: Generate Test Harness Data
```bash
cd devops_exercises/rclone

# Generate folder hierarchy and sample files
mkdir -p test_data/source/nested1/nested2 test_data/source/docs test_data/destination
echo "Sample text file 1" > test_data/source/nested1/sample1.txt
echo "%PDF-1.4 sample PDF" > test_data/source/nested1/nested2/sample.pdf
echo "Test notes" > test_data/source/docs/notes.txt

# Create 100MB and 1GB test binaries
fallocate -l 100M test_data/source/test_file_100M.bin
fallocate -l 1G test_data/test_file_1G.bin
```

### Step 2: Run Local Operations
```bash
# 1. Copy files to destination
./transfer.sh copy ./test_data/source ./test_data/destination

# 2. Verify idempotency (re-running transfers 0 bytes in 0 seconds)
./transfer.sh copy ./test_data/source ./test_data/destination

# 3. Check data integrity
./transfer.sh check ./test_data/source ./test_data/destination

# 4. Preview sync with --dry-run (safe preview of deletions)
./transfer.sh sync ./test_data/source ./test_data/destination --dry-run
```

### Step 3: Run S3 / MinIO Operations
```bash
# 1. Create target bucket
rclone mkdir myminio:exercise-bucket --config=/dev/null

# 2. Upload test data to S3
./transfer.sh copy ./test_data/source myminio:exercise-bucket/assets/

# 3. Verify S3 object integrity
./transfer.sh check ./test_data/source myminio:exercise-bucket/assets/

# 4. Upload 1GB large file with rate limiting (50MB/s)
./transfer.sh copy ./test_data/test_file_1G.bin myminio:exercise-bucket/large/ --bwlimit 50M
```

### Step 4: Inspect Operation Logs
```bash
tail -n 25 transfer.log
```

---

## 5. Documentation Index

For deeper technical details, refer to the companion documents:
- **[commands.md](commands.md)**: Exhaustive reference of every raw CLI command (`ls`, `lsl`, `lsd`, `copy`, `move`, `sync`, `check`, `delete`) and all CLI flags (`--bwlimit`, `--transfers`, `--checkers`, `--stats`, etc.).
- **[results.md](results.md)**: Real benchmark data, execution logs, server-side copy observations, and resilience tests.

---

## 6. Answers to Demonstration & Evaluation Questions

### Q1: What happens when `rclone copy` is executed twice with the same source and destination?
**Answer:**
`rclone copy` is **idempotent**. 
On the second execution, Rclone checks the metadata (file size and modification time, or checksum if `--checksum` is enabled) of every file at source and destination.
Because the files already match, Rclone skips them completely. 
**Observed Metric:** `Checks: 4/4 (100%), Transferred: 0 / 0 Bytes, Elapsed time: 0s`. Zero additional bandwidth or storage write operations are consumed.

---

### Q2: What happens if a file exists at the destination but not at the source when `rclone sync` runs?
**Answer:**
When `rclone sync` runs, Rclone forces the destination to become an exact duplicate of the source. 
Any file present at the destination that does not exist at the source is **permanently deleted**.
* **Demonstration:** Adding `extra_file.txt` to the destination caused `rclone sync` to report:
  `INFO: extra_file.txt: Deleted`.
* **Safety Precaution:** Never run `sync` against mission-critical storage without `--dry-run` first, or use `--backup-dir` to redirect deleted files to an archive directory.

---

### Q3: How does rclone determine whether a file needs to be transferred?
**Answer:**
By default, Rclone compares two attributes:
1. **File Size (in bytes)**: If sizes differ, the file is transferred.
2. **Modification Timestamp (ModTime)**: If timestamps differ beyond the filesystem's precision window (1 nanosecond on Linux, 1 second on S3/FAT), the file is transferred.

**Alternative Checksum Mode:**
If the `--checksum` flag is passed, Rclone ignores timestamps and calculates cryptographic hashes (MD5 on S3/MinIO, SHA1, or QuickXorHash). If hashes match, the transfer is skipped even if timestamps differ.

---

### Q4: Can rclone transfer data directly between two S3 providers without downloading it to the local machine?
**Answer:**
- **Same S3 Endpoint / Same Provider:** **Yes.** Rclone invokes the native S3 `CopyObject` API call (`Copied (server side copy)`). The transfer occurs entirely within the storage provider's infrastructure without passing over the local client network.
- **Between Two Different S3 Providers (e.g. AWS S3 to Wasabi/MinIO):** Rclone must stream the data through the host machine. However, Rclone streams it **directly in memory** (RAM buffers) without spooling or writing intermediate files to the local hard drive.

---

### Q5: What happens when a network connection is interrupted halfway through a 1 GB upload?
**Answer:**
For files larger than the multipart chunk threshold (default 5 MB on S3), Rclone uploads the file in parts using the S3 Multipart Upload API.
When interrupted:
1. Completed parts remain stored in the S3 bucket's pending multipart upload state.
2. When the transfer is re-initiated, Rclone detects the existing multipart upload ID or checks existing parts, verifies them, and resumes by uploading only the remaining missing chunks.
3. Once all parts arrive, the S3 service completes the multipart upload and forms the final unified object.

---

### Q6: How would you securely execute rclone from a Celery worker without maintaining an `rclone.conf` file?
**Answer:**
In a production Django/Celery worker environment:
1. **Never write an `rclone.conf` file to disk:** Writing static config files creates file lock contention across concurrent workers, risks leaving unencrypted API keys on disk, and violates the 12-Factor App design.
2. **Inject configuration via Process Environment Variables:**
   Configure Rclone dynamically by setting `RCLONE_CONFIG_<REMOTE>_<KEY>` in the Celery worker task process:
   ```python
   import subprocess
   import os

   def transfer_video_task(source_path, bucket_name, object_key):
       env = os.environ.copy()
       # Dynamically define remote 'minio_worker' in memory
       env["RCLONE_CONFIG_MINIO_WORKER_TYPE"] = "s3"
       env["RCLONE_CONFIG_MINIO_WORKER_PROVIDER"] = "Minio"
       env["RCLONE_CONFIG_MINIO_WORKER_ENDPOINT"] = settings.MINIO_ENDPOINT_URL
       env["RCLONE_CONFIG_MINIO_WORKER_ACCESS_KEY_ID"] = settings.MINIO_ACCESS_KEY_ID
       env["RCLONE_CONFIG_MINIO_WORKER_SECRET_ACCESS_KEY"] = settings.MINIO_SECRET_ACCESS_KEY

       cmd = [
           "rclone", "copy",
           source_path,
           f"minio_worker:{bucket_name}/{object_key}",
           "--config=/dev/null",  # Guarantee no file on disk is read or written
           "--retries=3",
           "--low-level-retries=10"
       ]

       result = subprocess.run(cmd, env=env, capture_output=True, text=True)
       if result.returncode != 0:
           raise Exception(f"Rclone transfer failed: {result.stderr}")
   ```
3. **Benefits:** 
   - Credentials exist strictly in the ephemeral process memory of that specific task.
   - Credentials never appear in `ps aux` command-line arguments.
   - Tasks can concurrently communicate with different tenants, buckets, and storage providers without collision.
