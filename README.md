## copyusagereport Oracle Function

This function copies OCI Cost/Usage reports from a **reporting bucket** into another Object Storage bucket.

### Getting Started

#### Clone the Repository

```bash
git clone https://github.com/mikarinneoracle/oci_usage_reports.git
cd oci_usage_reports
```

#### Configure Fn CLI Context

Before deploying, you need to configure the Fn CLI context for your target environment:

**For OCI (Cloud) deployment:**

```bash
fn use context oci
fn update context oracle.compartment-id <compartment-ocid>
fn update context oracle.provider <provider-url>
fn update context registry <registry-url>
```

**For Local deployment:**

```bash
fn use context default
fn update context api-url http://localhost:8080
fn update context registry ""
```

You can verify your current context:

```bash
fn list contexts
fn use context <context-name>
```

#### Deploy with Fn CLI

1. **Ensure you have Fn CLI installed** and are authenticated to your OCI environment (for cloud deployment) or have a local fn server running (for local deployment).

2. **Deploy the function**:

   ```bash
   fn deploy --app <app-name>
   ```

   Replace `<app-name>` with your Oracle Functions application name. If the application doesn't exist, create it first:

   ```bash
   fn create app <app-name>
   ```

3. **Set the required configuration** (see below).

4. **Invoke the function**:

   ```bash
   fn invoke <app-name> copyusagereport
   ```

### Required configuration

The function expects one required configuration key:
- `bucket_name` - The name of the target bucket where reports will be copied

**Optional but recommended:**
- `tenancy_ocid` - The tenancy OCID for the source reporting bucket. If not provided, it will be auto-retrieved:
  - From Resource Principal (when running as instance principal)
  - From OCI CLI config file (when using `/config` for local testing)

These are **not** configured in `func.yaml`; you must set them with the `fn` CLI.

### Optional configuration for cross-tenancy upload

The function supports cross-tenancy upload using Pre-Authenticated Requests (PAR):
- `x-tenancy_par` - Pre-authenticated request URL for uploading to a bucket in another tenancy
- `secret` - Secret value that will be base64-encoded and prepended to filenames when both `secret` and `x-tenancy_par` are provided

**⚠️ IMPORTANT - PAR Requirements:**
The PAR must be created at the **bucket root** with **write privileges**, **without any prefix (directory)**. The PAR should allow writing objects directly to the bucket root level.

**Cross-tenancy upload behavior:**
- If both `secret` and `x-tenancy_par` are provided, files will be uploaded via PAR with the secret prefix: `<base64_secret>_<original_filename>`
- If only `x-tenancy_par` is provided, files will be uploaded via PAR without secret prefix
- If neither is provided, standard upload within the same tenancy is used

#### Set config with `fn` CLI

Replace `<app-name>` and `<your_bucket_name_here>` with your values:

```bash
fn config function <app-name> copyusagereport bucket_name "<your_bucket_name_here>"
```

**Optional - set tenancy_ocid** (if auto-retrieval doesn't work):

```bash
fn config function <app-name> copyusagereport tenancy_ocid "<your_tenancy_ocid_here>"
```

**Optional - cross-tenancy upload** (if uploading to another tenancy):

```bash
fn config function <app-name> copyusagereport x-tenancy_par "<par_url_here>"
fn config function <app-name> copyusagereport secret "<your_secret_here>"
```

Note: If both `secret` and `x-tenancy_par` are set, filenames will be prefixed with the base64-encoded secret.

You can verify the values with:

```bash
fn inspect function <app-name> copyusagereport
```

Look under the `config` section for `tenancy_ocid` and `bucket_name`.

### Building for local fn server with Dockerfile.oci_cli

**⚠️⚠️⚠️ IMPORTANT: `Dockerfile.oci_cli` is ONLY for local testing ⚠️⚠️⚠️**

This Dockerfile embeds OCI credentials directly into the image and should **NEVER** be used for production deployments or pushed to any registry. Use it exclusively for local development and testing on your local fn server.

To build and run this function locally using `Dockerfile.oci_cli`, you need to provide OCI CLI credentials.

#### Prerequisites

1. **Local fn server**: Start your local fn server:

   ```bash
   fn start
   ```

2. **Fn CLI context**: Switch to local context:

   ```bash
   fn use context default
   fn update context api-url http://localhost:8080
   fn update context registry ""
   ```

3. **OCI CLI credentials**: You need a `.oci` directory with your OCI API credentials:
   - `.oci/config` - OCI configuration file
   - `.oci/oci_api_key.pem` - Your private API key file

   These files are typically located in `~/.oci/` when you install and configure OCI CLI.

#### Quick Start (Automated)

Use the provided script to automate the build and deployment:

```bash
./build-local.sh -a <app-name>
```

Or with a Docker registry:

```bash
./build-local.sh -a <app-name> -r <your-registry>
```

Use `./build-local.sh --help` for all options.

#### Manual Steps

Alternatively, you can follow these steps manually:

1. **Copy OCI credentials to the project directory**:

   ```bash
   mkdir -p .oci
   cp ~/.oci/config .oci/
   cp ~/.oci/oci_api_key.pem .oci/
   ```

   **⚠️ WARNING**: The `.oci` directory contains sensitive credentials. Do not commit it to version control. Ensure `.oci/` is in your `.gitignore`.

2. **Build the Docker image**:

   ```bash
   docker build -f Dockerfile.oci_cli -t copyusagereport:local .
   ```

3. **Deploy to local fn server**:

   ```bash
   fn deploy --local --app <app-name> --build-arg FN_REGISTRY=<your-registry> --dockerfile Dockerfile.oci_cli
   ```

   Or if you want to use the image you built:

   ```bash
   fn deploy --local --app <app-name> --image copyusagereport:local
   ```

4. **Set the configuration**:

   ```bash
   fn config function <app-name> copyusagereport tenancy_ocid "<your_tenancy_ocid_here>"
   fn config function <app-name> copyusagereport bucket_name "<your_bucket_name_here>"
   ```

5. **Invoke the function**:

   ```bash
   fn invoke <app-name> copyusagereport
   ```

#### Security Note

**⚠️ CRITICAL**: The `Dockerfile.oci_cli` embeds OCI credentials into the Docker image. This is **ONLY** for local testing. **DO NOT**:
- Push this image to any public registry
- Use this Dockerfile for production deployments
- Distribute or share images built with this Dockerfile

For production, use the standard `func.yaml` deployment which uses Resource Principals authentication instead of embedded credentials.

