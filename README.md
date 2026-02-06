## copyusagereport Oracle Function

This function copies OCI Cost/Usage reports from a **reporting bucket** into another Object Storage bucket.

**Note**: The function code is located in the `copyusagereport/` subdirectory. Make sure to navigate to that directory before deploying or building.

### Prebuilt Function Images

Prebuilt Docker images are available for quick deployment:

- **x86_64**: `mikarinneoracle/oci-copy-usage-report:x86`
- **ARM64**: `mikarinneoracle/oci-copy-usage-report:arm`

You can use these images directly without building from source. See deployment instructions below.

### Getting Started

#### Clone the Repository

```bash
git clone https://github.com/mikarinneoracle/oci_usage_reports.git
cd oci_usage_reports/copyusagereport
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

   **Option A: Deploy from source (builds from func.yaml)**:
   
   Make sure you're in the `copyusagereport` directory:
   ```bash
   cd copyusagereport
   fn deploy --app <app-name>
   ```

   **Option B: Deploy using prebuilt image**:
   
   For x86_64:
   ```bash
   fn deploy --app <app-name> --image mikarinneoracle/oci-copy-usage-report:x86
   ```
   
   For ARM64:
   ```bash
   fn deploy --app <app-name> --image mikarinneoracle/oci-copy-usage-report:arm
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

Make sure you're in the `copyusagereport` directory:
```bash
cd copyusagereport
./build-local.sh -a <app-name>
```

Or with a Docker registry:

```bash
cd copyusagereport
./build-local.sh -a <app-name> -r <your-registry>
```

Use `./build-local.sh --help` for all options.

#### Manual Steps

Alternatively, you can follow these steps manually:

1. **Navigate to the function directory and copy OCI credentials**:

   ```bash
   cd copyusagereport
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

   From the `copyusagereport` directory:
   ```bash
   fn deploy --local --app <app-name> --build-arg FN_REGISTRY=<your-registry>
   ```

   Note: The `fn deploy` command will automatically use the `Dockerfile` in the current directory (which is created from `Dockerfile.oci_cli` by the build script).

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

## xtenancycheck Function

The `xtenancycheck` function validates uploaded files in Object Storage by checking if they have the correct secret prefix (base64-encoded secret followed by underscore). Files without the correct prefix are automatically deleted.

### Function Overview

This function is designed to be triggered by Object Storage bucket write events. It:
- Validates filenames against a configured secret prefix
- Deletes files that don't match the expected pattern
- Logs security alerts for unauthorized uploads

### Prebuilt Function Images

Prebuilt Docker images are available for quick deployment:

- **x86_64**: `mikarinneoracle/oci-xtenancy-check:x86`
- **ARM64**: `mikarinneoracle/oci-xtenancy-check:arm`

You can use these images directly without building from source. See deployment instructions below.

### Required Configuration

The function requires one configuration key:
- `secret` - Secret value that will be base64-encoded and used to validate file prefixes

Set it with:
```bash
fn config function <app-name> xtenancycheck secret "<your_secret_here>"
```

**Note**: This secret must match the secret used in `copyusagereport` function when uploading files with the `x-tenancy_par` option.

### Deployment

#### Deploy with Fn CLI

1. **Navigate to the function directory**:
   ```bash
   cd xtenancycheck
   ```

2. **Deploy the function**:
   
   **Option A: Deploy from source (builds from func.yaml)**:
   ```bash
   fn deploy --app <app-name>
   ```
   
   **Option B: Deploy using prebuilt image**:
   
   For x86_64:
   ```bash
   fn deploy --app <app-name> --image mikarinneoracle/oci-xtenancy-check:x86
   ```
   
   For ARM64:
   ```bash
   fn deploy --app <app-name> --image mikarinneoracle/oci-xtenancy-check:arm
   ```
   
   Replace `<app-name>` with your Oracle Functions application name. If the application doesn't exist, create it first:
   ```bash
   fn create app <app-name>
   ```

3. **Set the required configuration** (see Required Configuration above).

### Configuring OCI Object Storage Events

To automatically trigger `xtenancycheck` when files are uploaded to a bucket, configure an Object Storage event:

#### Prerequisites

1. Deploy the `xtenancycheck` function (see deployment instructions above)
2. Ensure the function has proper IAM policies to delete objects from the target bucket

#### Steps to Configure Event Rule

1. **Navigate to Events Service**:
   - Go to OCI Console → Developer Services → Events
   - Select your compartment

2. **Create an Event Rule**:
   - Click "Create Rule"
   - **Rule Name**: e.g., `xtenancycheck-bucket-events`
   - **Description**: "Trigger xtenancycheck function on bucket writes"

3. **Configure Event Conditions**:
   - **Event Type**: Select `Object Storage`
   - **Service Name**: `Object Storage`
   - **Event Type**: `Object - Create`
   - **Attribute**: Leave default or filter as needed

4. **Select Compartment and Bucket**:
   - **Compartment**: Select the compartment containing your target bucket
   - **Bucket Name**: Select the specific bucket where files will be uploaded
   - **Note**: You can create multiple rules for different buckets if needed

5. **Configure Action**:
   - **Action Type**: `Functions`
   - **Function Compartment**: Select compartment where your function is deployed
   - **Function Application**: Select your Functions application
   - **Function**: Select `xtenancycheck`
   - **Function Payload**: Leave empty (event data is automatically passed)

6. **Enable the Rule**:
   - Ensure "Enabled" is checked
   - Click "Create Rule"

#### Verification

After creating the event rule:
1. Upload a test file to the bucket (with correct secret prefix)
2. Upload a test file without the secret prefix
3. Check function logs to verify:
   - Valid files are allowed
   - Invalid files are deleted

#### Example Event Rule Configuration

```
Rule Name: xtenancycheck-validation
Event Type: Object Storage - Object - Create
Compartment: <your-compartment>
Bucket: <your-bucket-name>
Action: Functions
Function: xtenancycheck
```

#### IAM Policies Required

Ensure the function's dynamic group has these policies:

```hcl
Allow dynamic-group <function-dynamic-group> to manage objects in compartment <compartment-name> where target.bucket.name='<bucket-name>'
Allow dynamic-group <function-dynamic-group> to read objectstorage-namespace in compartment <compartment-name>
```

### Testing the Function

You can test the function manually:

```bash
# Test with valid filename (has secret prefix)
fn invoke <app-name> xtenancycheck --content '{
  "data": {
    "resourceName": "<base64_secret>_testfile.csv.gz",
    "additionalDetails": {
      "namespace": "<namespace>",
      "bucketName": "<bucket-name>"
    }
  }
}'

# Test with invalid filename (no secret prefix)
fn invoke <app-name> xtenancycheck --content '{
  "data": {
    "resourceName": "unauthorized_file.csv.gz",
    "additionalDetails": {
      "namespace": "<namespace>",
      "bucketName": "<bucket-name>"
    }
  }
}'
```

### Function Behavior

- **Valid files** (filename starts with `base64(secret)_`): Allowed, function returns success
- **Invalid files** (filename doesn't match): Deleted automatically, security alert logged
- **Missing secret**: Function returns error
- **Missing namespace/bucket**: Function returns error with details

