# Rclone Commands Reference & Explanations

This document catalogues the tested `rclone` commands used across all stages of the DevOps exercise, including their purpose, flags, and operational mechanics, directly following the structure of the requirements document.

---

## 2. Basic File Operations

### A. Listing Files and Directories
* **List all files with sizes recursively:**
  ```bash
  rclone ls test_data/source/
  ```
  *Prints the file size (in bytes) and relative path of every file in the source tree.*

* **List directories only:**
  ```bash
  rclone lsd test_data/source/
  ```
  *Lists directory names, object counts, and modification times.*

* **List files with modification times:**
  ```bash
  rclone lsl test_data/source/
  ```

* **Clean flat listing (directory-aware):**
  ```bash
  rclone lsf test_data/source/
  ```
  *Prints names cleanly, appending `/` to subdirectories (ideal for shell scripts).*

---

### B. Copying Files (`rclone copy`)
```bash
rclone copy test_data/source/ test_data/destination/ -P --stats-one-line
```
* **Behavior:** Transfers new or modified files from source to destination.
* **Flags:**
  - `-P` / `--progress`: Shows live transfer speed, percentage completed, and ETA.
  - `--stats-one-line`: Condenses periodic progress into a single updating terminal line.
* **Idempotency (Second Execution):**
  ```bash
  rclone copy test_data/source/ test_data/destination/ -v
  ```
  *Output confirms: `Transferred: 0 / 0 Bytes, Checks: 4 / 4, Transferred: 0 / 0`. Pre-existing identical files are skipped.*

---

### C. Moving Files (`rclone move`)
```bash
rclone move test_data/move_src/ test_data/move_dst/ -v
```
* **Behavior:** Transfers files to destination and immediately deletes them from the source upon verified completion.

---

### D. Synchronizing Directories (`rclone sync`)
```bash
# Step 1: Preview changes and deletions safely
rclone sync test_data/source/ test_data/destination/ --dry-run -v

# Step 2: Execute actual sync
rclone sync test_data/source/ test_data/destination/ -v
```
* **Behavior:** Forces `<destination>` to become an exact duplicate of `<source>`.
* **Important:** Any file present in destination but absent in source is **permanently deleted**.
* **Flags:**
  - `--dry-run`: Runs a trial without making permanent changes; prints `NOTICE: <file>: Not deleting as --dry-run`.
  - `-v`: Verbose output to track every checked, transferred, or deleted file.

---

### E. Integrity Checking (`rclone check`)
```bash
rclone check test_data/source/ test_data/destination/
```
* **Behavior:** Compares source and destination without transferring or deleting anything.
* **Output:**
  ```
  NOTICE: Local file system: 0 differences found
  NOTICE: Local file system: 4 matching files
  ```

---

### F. Deleting Files from Destination (`rclone delete`)
```bash
# Delete a specific file
rclone delete test_data/destination/temp.txt -v

# Delete all files matching a specific pattern
rclone delete test_data/destination/ --include "*.tmp" -v
```

---

## 3. S3-Compatible Storage

Configure rclone to communicate with your locally hosted S3-compatible storage service (MinIO).

### Pre-requisite: Export Environment Variables (Configuration-Free)
```bash
export RCLONE_CONFIG_MYMINIO_TYPE="s3"
export RCLONE_CONFIG_MYMINIO_PROVIDER="Minio"
export RCLONE_CONFIG_MYMINIO_ENDPOINT="http://localhost:9000"
export RCLONE_CONFIG_MYMINIO_ACCESS_KEY_ID="MINIO_ACCESS_KEY"
export RCLONE_CONFIG_MYMINIO_SECRET_ACCESS_KEY="MINIO_SECRET_ACCESS_KEY"
```

### Demonstration:

#### 1. Creating a bucket
Create a new bucket on the MinIO server:
```bash
rclone mkdir myminio:rclone-bucket-1 --config=/dev/null -v
rclone mkdir myminio:rclone-bucket-2 --config=/dev/null -v
```
* **List all buckets to verify:**
  ```bash
  rclone lsd myminio: --config=/dev/null
  ```

#### 2. Uploading files to the bucket
Upload a local directory to a bucket:
```bash
rclone copy test_data/source/ myminio:rclone-bucket-1/assets/ --config=/dev/null -v -P
```
* Uploads directory trees, documents, and large binaries (`test_file_100M.bin`) preserving relative paths.

#### 3. Downloading files from the bucket
Download files from the MinIO bucket to a local directory:
```bash
mkdir -p test_data/downloaded
rclone copy myminio:rclone-bucket-1/assets/ test_data/downloaded/ --config=/dev/null -v -P
```

#### 4. Listing objects in the bucket
* **List all objects with byte sizes:**
  ```bash
  rclone ls myminio:rclone-bucket-1/ --config=/dev/null
  ```
* **List objects with directory hierarchy (`lsf`):**
  ```bash
  rclone lsf myminio:rclone-bucket-1/assets/ --config=/dev/null
  ```
* **List objects with detailed JSON metadata (timestamps, hashes, MIME types):**
  ```bash
  rclone lsjson myminio:rclone-bucket-1/assets/ --config=/dev/null
  ```

#### 5. Copying files between two buckets (Server-Side Copy)
Copy objects directly from `rclone-bucket-1` to `rclone-bucket-2`:
```bash
rclone copy myminio:rclone-bucket-1/assets/ myminio:rclone-bucket-2/backup/ --config=/dev/null -v
```
* **Key Mechanism:** Output displays `Copied (server side copy)`. The transfer occurs directly inside MinIO's storage layer using the S3 `CopyObject` API call, without streaming bytes to or from the local machine's disk!

#### 6. Deleting objects from a bucket
* **Delete a single object from a bucket:**
  ```bash
  rclone delete myminio:rclone-bucket-2/backup/nested1/sample1.txt --config=/dev/null -v
  ```
* **Delete all objects in a bucket path:**
  ```bash
  rclone delete myminio:rclone-bucket-2/backup/ --config=/dev/null -v
  ```
* **Delete an empty bucket:**
  ```bash
  rclone rmdir myminio:rclone-bucket-2 --config=/dev/null -v
  ```

---

## 4. Configuration-Free Execution

The exercise mandates running operations without creating or depending on an `rclone.conf` file. Three distinct methods were verified:

### Method 1: Environment Variables (`RCLONE_CONFIG_<REMOTE>_*`) [Recommended for Production]
Rclone dynamically provisions remotes in memory from environment variables:
```bash
export RCLONE_CONFIG_MYMINIO_TYPE="s3"
export RCLONE_CONFIG_MYMINIO_PROVIDER="Minio"
export RCLONE_CONFIG_MYMINIO_ENDPOINT="http://localhost:9000"
export RCLONE_CONFIG_MYMINIO_ACCESS_KEY_ID="MINIO_ACCESS_KEY"
export RCLONE_CONFIG_MYMINIO_SECRET_ACCESS_KEY="MINIO_SECRET_ACCESS_KEY"

# Enforce zero config file with --config=/dev/null
rclone lsd myminio: --config=/dev/null
```

### Method 2: Command-Line Flags with Generic `:s3:` Remote
```bash
rclone lsd :s3: \
  --s3-provider=Minio \
  --s3-endpoint="http://localhost:9000" \
  --s3-access-key-id="MINIO_ACCESS_KEY" \
  --s3-secret-access-key="MINIO_SECRET_ACCESS_KEY" \
  --config=/dev/null
```

### Method 3: Standard AWS Environment Variables
```bash
export AWS_ACCESS_KEY_ID="MINIO_ACCESS_KEY"
export AWS_SECRET_ACCESS_KEY="MINIO_SECRET_ACCESS_KEY"

rclone lsd :s3: \
  --s3-provider=Minio \
  --s3-endpoint="http://localhost:9000" \
  --s3-env-auth=true \
  --config=/dev/null
```

---

## 5. Transfer Reliability & Performance Tuning

### A. Uploading Large Files (1 GB+)
```bash
rclone copy test_data/test_file_1G.bin myminio:rclone-bucket-1/large/ \
  --config=/dev/null \
  -P
```

### B. Bandwidth Throttling (`--bwlimit`)
Limits transfer rate to prevent network saturation:
```bash
rclone copy test_data/test_file_1G.bin myminio:rclone-bucket-1/large/ \
  --config=/dev/null \
  --bwlimit 50M \
  -v --stats 2s
```

### C. Concurrency Control (`--transfers` and `--checkers`)
```bash
rclone copy test_data/source/ myminio:rclone-bucket-1/assets/ \
  --transfers 4 \
  --checkers 8 \
  --config=/dev/null
```
* `--transfers`: Maximum number of parallel file transfers (default: 4).
* `--checkers`: Maximum number of parallel file checkers / directory crawlers (default: 8).

### D. Automatic Retries
```bash
rclone copy test_data/source/ myminio:rclone-bucket-1/assets/ \
  --retries 5 \
  --low-level-retries 20 \
  --config=/dev/null
```
* `--retries`: Re-attempts entire failed transfer operation up to N times (default: 3).
* `--low-level-retries`: Re-attempts individual HTTP/S3 network request failures up to N times (default: 10).

---

## 6. Synchronization and Data Safety

### A. Pre-synchronization Inspection (`--dry-run`)
```bash
rclone sync test_data/source myminio:rclone-bucket-1/assets/ --dry-run -v --config=/dev/null
```
* Identifies missing, modified, or extraneous files that would be deleted **before** any changes are written.

### B. Checksum Verification (`rclone check`)
```bash
rclone check test_data/source myminio:rclone-bucket-1/assets/ --config=/dev/null
```
* Verifies byte size and cryptographic hashes between local files and S3 objects.

---

## 7. Automation with `transfer.sh`

```bash
# 1. Copy operation
./transfer.sh copy ./test_data/source myminio:rclone-bucket-1/automated/

# 2. Sync operation with safety dry-run
./transfer.sh sync ./test_data/source myminio:rclone-bucket-1/automated/ --dry-run

# 3. Check operation
./transfer.sh check ./test_data/source myminio:rclone-bucket-1/automated/
```
