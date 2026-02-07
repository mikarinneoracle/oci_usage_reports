# Build and Run Locally with Fn Server

Both functions can be built and run locally using `build-local.sh`. Local deployment is the **default** (equivalent to `--local`). This uses a local Fn server and OCI CLI credentials for authentication.

**Note**: You can also deploy the `build-local.sh` image to OCI (instead of using Resource Principal) by pushing to a **private** OCIR repository (strictly required). Use this only when you need CLI config or IAM user credentials instead of Resource Principal. **Resource Principal is recommended for production.**

## Prerequisites

- Local fn server: `fn start` (or use the [Docker fallback](#if-fn-start-fails) below)
- Fn CLI context for **local only**:

  ```bash
  fn use context default
  fn update context api-url http://localhost:8080
  fn update context registry ""
  ```

- **OCI CLI credentials** when using CLI auth (instead of Resource Principal): copy `~/.oci` into the function directory. `build-local.sh` expects `config` and `oci_api_key.pem` in the function's `.oci/` subdir; it will copy from `~/.oci/` if missing. Required for both copyusagereport and xtenancycheck.

## copyusagereport (Local)

1. **Clone and navigate**:

   ```bash
   git clone https://github.com/mikarinneoracle/oci_usage_reports.git
   cd oci_usage_reports/copyusagereport
   ```

2. **Copy OCI credentials** (CLI auth): ensure `~/.oci` is available. `build-local.sh` copies it into the function dir if `.oci/` is missing:
   ```bash
   mkdir -p .oci && cp ~/.oci/config ~/.oci/oci_api_key.pem .oci/
   ```

3. **Run build-local.sh** (local is default):

   ```bash
   ./build-local.sh -a <app-name>
   ```

   Or with a private OCIR registry (e.g. when deploying to OCI with CLI config instead of Resource Principal):

   ```bash
   ./build-local.sh -a <app-name> -r <region-key>.ocir.io/<tenancy-namespace>/<repo-name>
   ```

4. **Configure**:

   **Required configuration**:
   | Config key | Meaning |
   |------------|---------|
   | `bucket_name` | Target bucket where usage reports will be copied |

   ```bash
   fn config function <app-name> copyusagereport bucket_name "<your_bucket_name>"
   ```

   **Optional configuration**:
   | Config key | Meaning |
   |------------|---------|
   | `tenancy_ocid` | Tenancy OCID of the source reporting bucket. Omit to auto-detect from CLI config. |
   | `x-tenancy_par` | Pre-authenticated Request (PAR) URL for cross-tenancy upload. Use only with `secret`. |
   | `secret` | Secret value; base64-encoded and prepended to filenames. Enables xtenancycheck validation for in-tenancy and cross-tenancy. |

   ```bash
   # Optional – only if auto-detect fails
   fn config function <app-name> copyusagereport tenancy_ocid "<tenancy_ocid>"

   # Optional – for cross-tenancy upload (both required together)
   fn config function <app-name> copyusagereport x-tenancy_par "<par_url>"
   fn config function <app-name> copyusagereport secret "<your_secret>"
   ```

   PAR must be created at the **bucket root** with **write** privileges and **no prefix**.

5. **Invoke**:

   ```bash
   fn invoke <app-name> copyusagereport
   ```

**Note**: `Dockerfile.oci_cli` embeds OCI credentials and must **not** be used for production or pushed to a public registry.

## xtenancycheck (Local)

1. **Navigate** (from repo root, after cloning):

   ```bash
   cd oci_usage_reports/xtenancycheck
   ```

2. **Copy OCI credentials** (CLI auth): same as copyusagereport; ensure `~/.oci` is copied into the function dir:
   ```bash
   mkdir -p .oci && cp ~/.oci/config ~/.oci/oci_api_key.pem .oci/
   ```

3. **Run build-local.sh** (local is default):

   ```bash
   ./build-local.sh -a <app-name>
   ```

   Or with private OCIR (for OCI deployment with CLI config):

   ```bash
   ./build-local.sh -a <app-name> -r <region-key>.ocir.io/<tenancy-namespace>/<repo-name>
   ```

4. **Configure**:

   **Required configuration**:
   | Config key | Meaning |
   |------------|---------|
   | `secret` | Same secret as copyusagereport. Files whose names don't start with `base64(secret)_` are deleted. |

   ```bash
   fn config function <app-name> xtenancycheck secret "<your_secret>"
   ```

5. **Invoke** (test payload):

   ```bash
   fn invoke <app-name> xtenancycheck --content '{
     "data": {
       "resourceName": "<base64_secret>_testfile.csv.gz",
       "additionalDetails": {
         "namespace": "<namespace>",
         "bucketName": "<bucket-name>"
       }
     }
   }'
   ```

## IAM Policies (Dynamic Group)

When using Resource Principal in OCI:

```hcl
Allow dynamic-group <dynamic-group-name> to manage objects in compartment <compartment-name>
Allow dynamic-group <dynamic-group-name> to read objectstorage-namespace in compartment <compartment-name>
```

For `xtenancycheck` on a specific bucket:

```hcl
Allow dynamic-group <dynamic-group-name> to manage objects in compartment <compartment-name> where target.bucket.name='<bucket-name>'
```

## If fn start fails

If `fn start` fails to run the function (for example when using Rancher Desktop instead of Docker), use the Fn server via Docker directly:

```bash
docker run --rm -i --name fnserver \
  -v /tmp/iofs:/iofs \
  -e FN_IOFS_DOCKER_PATH=/tmp/iofs \
  -e FN_IOFS_PATH=/iofs \
  -v /tmp/data:/app/data \
  -v /var/run/docker.sock:/var/run/docker.sock \
  --privileged \
  -p 8080:8080 \
  --entrypoint ./fnserver \
  -e FN_LOG_LEVEL=DEBUG fnproject/fnserver:latest
```

Ensure your Fn CLI context points to `http://localhost:8080`, then run `build-local.sh` as usual.
