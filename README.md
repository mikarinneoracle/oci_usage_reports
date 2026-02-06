## copyusagereport Oracle Function

This function copies OCI Cost/Usage reports from a **reporting bucket** into another Object Storage bucket.

### Required configuration

The function expects two configuration keys:
- `tenancy_ocid` - The tenancy OCID for the source reporting bucket
- `bucket_name` - The name of the target bucket where reports will be copied

These are **not** configured in `func.yaml`; you must set them with the `fn` CLI.

#### Set config with `fn` CLI

Replace `<app-name>`, `<your_tenancy_ocid_here>`, and `<your_bucket_name_here>` with your values:

```bash
fn config function <app-name> copyusagereport tenancy_ocid "<your_tenancy_ocid_here>"
fn config function <app-name> copyusagereport bucket_name "<your_bucket_name_here>"
```

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

1. **OCI CLI credentials**: You need a `.oci` directory with your OCI API credentials:
   - `.oci/config` - OCI configuration file
   - `.oci/oci_api_key.pem` - Your private API key file

   These files are typically located in `~/.oci/` when you install and configure OCI CLI.

#### Steps

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
- Push this image to any registry (public or private)
- Use this Dockerfile for production deployments
- Distribute or share images built with this Dockerfile

For production, use the standard `func.yaml` deployment which uses Resource Principals authentication instead of embedded credentials.

