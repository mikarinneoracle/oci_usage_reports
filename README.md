# OCI Usage Reports Management Functions

This repository contains Oracle Functions for managing OCI Cost/Usage reports, including copying reports within a tenancy or across tenancies, and validating cross-tenancy uploads.

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

### Authentication and Deployment

Both functions run as **Resource Principal** by default when deployed to Oracle Functions. This requires:

1. **Dynamic Group**: Create a dynamic group that includes your function
2. **IAM Policies**: Grant the dynamic group Object Storage and namespace permissions

For local development, both functions can be built using the `build-local.sh` script in each function's directory, which uses user CLI config for IAM credentials (instead of Resource Principal).

## Documentation

- **[Fn Build for OCI](fn-build-for-oci.md)** – Install Fn, clone repo, create VCN/OCIR, deploy from source; OCI scheduling for copyusagereport; Object Storage events for xtenancycheck
- **[Using Prebuilt Functions](using-prebuilt-functions.md)** – Deploy prebuilt Docker images (VCN, OCIR, pull/tag/push/deploy); same scheduling and event setup
- **[Local Development](local-dev.md)** – Build and run locally with Fn server; optionally deploy to OCI with private OCIR when using CLI config instead of Resource Principal
