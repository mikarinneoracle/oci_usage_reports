# OCI Usage Reports Management Functions

This repository contains Oracle Functions for managing OCI Cost/Usage reports, including copying reports within a tenancy or across tenancies, and validating cross-tenancy uploads.

**Easiest way to get usage reports running:** use the **scripted installer** (`scripts/install-usage-reports.sh`). It creates the VCN, bucket, and both functions (copyusagereport and optionally xtenancycheck) via the OCI CLI and guides you through each step. The other approaches (Fn CLI, build from source, local Fn server) are only needed if you want to **custom-build and test** the functions yourself.

## Overview

### copyusagereport Function

The `copyusagereport` function copies OCI Cost/Usage reports from a **reporting bucket** into another Object Storage bucket. It supports:

- **Same-tenancy copying**: Copy reports to buckets within the same tenancy
- **Cross-tenancy copying**: Copy reports to buckets in another tenancy using a Pre-Authenticated Request (PAR) and secret prefix

When configured with both `secret` and `x-tenancy_par` parameters, the function automatically prefixes filenames with a base64-encoded secret (format: `<base64_secret>_<original_filename>`) to enable secure cross-tenancy validation.

### xtenancycheck Function

The `xtenancycheck` function validates uploaded files in Object Storage by checking if they have the correct secret prefix (base64-encoded secret followed by underscore). This function is designed to work in conjunction with `copyusagereport` for cross-tenancy scenarios:

- **Automatic validation**: Triggered by Object Storage bucket write events
- **Security enforcement**: Files without the correct secret prefix are automatically deleted
- **Security logging**: Unauthorized upload attempts are logged as security alerts

**Workflow**: When `copyusagereport` uploads files to a cross-tenancy bucket with a secret prefix, `xtenancycheck` validates those files and removes any unauthorized uploads that don't match the expected pattern.

- **copyusagereport**: Run on demand or schedule via [OCI Resource Scheduler](https://docs.oracle.com/en-us/iaas/Content/Functions/Tasks/functionsscheduling.htm) (e.g. daily).
- **xtenancycheck**: Triggered by Object Storage bucket **Object - Create** (and optionally **Object - Update**) events. Configure an event rule in OCI Events Service pointing to the target bucket and the `xtenancycheck` function.

### Multi-tenancy Cross-Tenancy Setup

When setting up **cross-tenancy reports**, you may want to:

- **Deploy both functions (`copyusagereport` and `xtenancycheck`) into each participating tenancy**, and
- **Share a common `secret` value and bucket-level PAR URL between those tenancies.**

In this pattern:

- One tenancy **hosts the destination reports bucket** and the **PAR** (created on that bucket).
- All other tenancies:
  - Deploy their own `copyusagereport` and `xtenancycheck` functions.
  - Configure the **same `secret`** and **same PAR URL** on their `copyusagereport` function.
  - Configure the **same `secret`** on their `xtenancycheck` function that protects the destination bucket.

As a result, **multiple tenancies** can upload reports into the **same bucket** (in the PAR-hosting tenancy), while `xtenancycheck` enforces the shared secret prefix. This setup requires you to have **credentials and permissions in all involved tenancies** (one hosting the reports bucket and any number of “source” tenancies).

### Authentication and Deployment

Both functions run as **Resource Principal** by default when deployed to Oracle Functions. This requires:

1. **Dynamic Group**: Create a dynamic group that includes your function
2. **IAM Policies**: Grant the dynamic group Object Storage and namespace permissions

For local development, both functions can be built using the `build-local.sh` script in each function's directory, which uses user CLI config for IAM credentials (instead of Resource Principal).

## Scripted Install (recommended)

The installer is the simplest way to deploy usage-report functions.

### Clone and run

From **OCI Cloud Shell** (open via the terminal icon in the OCI Console) or **macOS (localhost)**:

1. Clone the repo over HTTPS, source `scripts/.env` (optional defaults), and run the installer.
2. When prompted for where to run: use the default **1** (Cloud Shell) if in Cloud Shell, or choose **2** (Localhost) on macOS. On localhost the script will ask for your OCI CLI config path and profile.

```bash
git clone https://github.com/mikarinneoracle/oci_usage_reports.git
cd oci_usage_reports
source scripts/.env
./scripts/install-usage-reports.sh
```

### Optional: settings in `scripts/.env`

You can set these in `scripts/.env` so the installer uses them as defaults (no need to type them every time). All are optional.

| Variable | Meaning | Example |
|----------|---------|--------|
| `INSTALLER_CHOICE` | Where to run: `1` = Cloud Shell, `2` = Localhost, `3` = Quit | *(configure)* |
| `COMPARTMENT_NAME` | Compartment for the Functions application | *(configure)* |
| `APP_NAME` | OCI Functions application name | `oci-usage-reports-app` |
| `ARCH` | Architecture for prebuilt images: `x86` or `arm` | *(configure)* |
| `OCIR_REPO_NAME` | OCIR repository name for pushed images | `oci-usage-reports` |
| `BUCKET_NAME` | Target bucket for copyusagereport | `copyusagereport` |
| `VCN_NAME` | VCN name when creating a new VCN | `oci-usage-reports` |
| `SUBNET_NAME` | Private subnet name when creating a new VCN | `oci-usage-reports-private` |
| `VCN_CIDR` | VCN CIDR when creating a new VCN | `10.0.0.0/16` |
| `SUBNET_CIDR` | Subnet CIDR when creating a new VCN | `10.0.1.0/24` |
| `PAR_TTL_DAYS` | PAR validity in days when creating a new PAR | `365` |

### What the installer does (briefly)

1. **Where to run** – Choose Cloud Shell (1) or Localhost (2). On localhost, it configures OCI CLI config path and profile.
2. **Region, namespace, bucket** – Prompts for OCI region, OCIR namespace, and target bucket name for copyusagereport.
3. **Architecture** – Select x86 or arm for prebuilt images and app shape.
4. **Functions application** – Asks for compartment and app name; creates a new VCN with private subnet (and Service Gateway + route for OCIR) or lets you pick an existing subnet, then creates the OCI Functions application.
5. **OCIR auth** – Authentication method depends on where you run the installer:
   - **Cloud Shell**: Prompts if you want to login to OCIR (default: no). If yes, prompts for OCIR username and identity domain, then asks you to manually create an auth token in your user profile and enter it. The script attempts login immediately; if it fails, waits 60 seconds and retries up to 2 more times.
   - **Localhost**: Uses OCI CLI-based authentication with a short-lived bearer token (no username/token needed).
6. **Docker** – Logs in to OCIR, pulls prebuilt images, tags and pushes them to your OCIR repo.
7. **Bucket** – Ensures the target Object Storage bucket exists in the app’s compartment (creates it if missing).
8. **Secret and PAR** – Asks for a secret (optional; used for cross-tenancy and xtenancycheck). If given, offers: create a new PAR (with TTL in days), use an existing PAR URL, or skip. PAR URL is stored in copyusagereport config.
9. **copyusagereport** – Creates the function with config (bucket, days, optional secret and `x-tenancy_par`).
10. **xtenancycheck (optional)** – If a secret was set, offers to deploy xtenancycheck with the same secret.
11. **Quick test (optional)** – Can invoke copyusagereport and run a short xtenancycheck test (upload/delete object with secret prefix).

After deployment, schedule **copyusagereport** (e.g. via OCI Resource Scheduler) and attach **xtenancycheck** to the bucket’s Object Storage events (see [Multi-tenancy](#multi-tenancy-cross-tenancy-setup) and the linked docs).

## Documentation

- **[Scripted Install (recommended)](#scripted-install-recommended)** – Easiest option: run `scripts/install-usage-reports.sh` for an interactive installer (VCN, bucket, both functions, optional PAR). Use other approaches only if you need to custom-build and test.
- **[Fn Build for OCI](fn-build-for-oci.md)** – Install Fn, clone repo, create VCN/OCIR, deploy from source; OCI scheduling for copyusagereport; Object Storage events for xtenancycheck
- **[Using Prebuilt Functions](using-prebuilt-functions.md)** – Deploy prebuilt Docker images manually (VCN, OCIR, pull/tag/push/deploy); same scheduling and event setup
- **[Local Development](local-dev.md)** – Build and run locally with Fn server; optionally deploy to OCI with private OCIR when using CLI config instead of Resource Principal

