# Using Prebuilt Images in OCI Functions

Prebuilt Docker images are available on Docker Hub. They must be pulled, tagged for OCIR, and pushed to your Oracle Cloud Infrastructure Registry before use. **ARM64 images are also available**; examples below use x86.

## Prebuilt Images

| Function         | x86                               | ARM64                             |
|------------------|-----------------------------------|-----------------------------------|
| copyusagereport  | `mikarinneoracle/oci-copy-usage-report:x86`  | `mikarinneoracle/oci-copy-usage-report:arm`  |
| xtenancycheck    | `mikarinneoracle/oci-xtenancy-check:x86`     | `mikarinneoracle/oci-xtenancy-check:arm`     |

## Step 1: Create Function Application with VCN (Private Subnet)

1. In OCI Console, go to **Developer Services** → **Networking** and create a **VCN** if you don't have one
2. Create a **private subnet** in the VCN
3. Go to **Developer Services** → **Applications** (Functions)
4. Click **Create Application**
5. **Name**: e.g., `usage-reports-app`
6. **VCN**: Select your VCN
7. **Subnets**: Select your **private subnet**
8. Create the application

## Step 2: Create OCIR Repository

1. Go to **Developer Services** → **Container Registry**
2. Click **Create Repository**
3. **Name**: e.g., `oci-usage-reports`
4. **Access**: Private (recommended) or Public
5. Create the repository
6. Note your registry URL: `<region-key>.ocir.io/<tenancy-namespace>/<repo-name>`

## Step 3: Pull, Tag, Push, and Deploy

Configure Fn CLI for OCI:

```bash
fn use context oci
fn update context oracle.compartment-id <compartment-ocid>
fn update context oracle.provider <provider-url>
fn update context registry <region-key>.ocir.io/<tenancy-namespace>
```

### copyusagereport

```bash
# Pull from Docker Hub
docker pull mikarinneoracle/oci-copy-usage-report:x86

# Login to OCIR
docker login <region-key>.ocir.io
# Use: <tenancy-namespace>/<username>, Auth Token as password

# Tag for OCIR
docker tag mikarinneoracle/oci-copy-usage-report:x86 <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-copy-usage-report:x86

# Push to OCIR
docker push <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-copy-usage-report:x86

# Deploy
cd copyusagereport
fn deploy --app <app-name> --image <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-copy-usage-report:x86
```

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
| `tenancy_ocid` | Tenancy OCID of the source reporting bucket. Omit to auto-detect from Resource Principal. |
| `x-tenancy_par` | Pre-authenticated Request (PAR) URL for cross-tenancy upload. Use only with `secret`; both must be set for PAR upload. |
| `secret` | Secret value; base64-encoded and prepended to filenames when defined. Enables xtenancycheck validation for both in-tenancy and cross-tenancy. |

```bash
# Optional – only if auto-detect fails
fn config function <app-name> copyusagereport tenancy_ocid "<tenancy_ocid>"

# Optional – for cross-tenancy upload
fn config function <app-name> copyusagereport x-tenancy_par "<par_url>"
fn config function <app-name> copyusagereport secret "<your_secret>"
```

PAR must be created at the **bucket root** with **write** privileges and **no prefix**.

**OCI Scheduling**: `copyusagereport` runs on demand; to run it periodically (e.g. daily), use OCI Resource Scheduler. See [Scheduling a Function](https://docs.oracle.com/en-us/iaas/Content/Functions/Tasks/functionsscheduling.htm). From the Functions Console: select the function → **Schedules** → **Add Schedule** → create or select a schedule (cron, daily, etc.). Create a dynamic group and policy for the schedule.

### xtenancycheck

```bash
# Pull from Docker Hub
docker pull mikarinneoracle/oci-xtenancy-check:x86

# Tag for OCIR
docker tag mikarinneoracle/oci-xtenancy-check:x86 <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-xtenancy-check:x86

# Push to OCIR
docker push <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-xtenancy-check:x86

# Deploy
cd xtenancycheck
fn deploy --app <app-name> --image <region-key>.ocir.io/<tenancy-namespace>/<repo-name>/oci-xtenancy-check:x86
```

**Required configuration**:
| Config key | Meaning |
|------------|---------|
| `secret` | Same secret as copyusagereport. Files whose names don't start with `base64(secret)_` are deleted. |

```bash
fn config function <app-name> xtenancycheck secret "<your_secret>"
```

**Object Storage event triggering**: `xtenancycheck` must be triggered by Object Storage bucket events. Configure an event rule in OCI Events Service:

1. **Developer Services** → **Events** → **Create Rule**
2. **Event Type**: Object Storage → **Object - Create** (and optionally **Object - Update** for overwrites)
3. **Compartment / Bucket**: Select the bucket where files are uploaded
4. **Action**: Functions → select your application and `xtenancycheck` function

The event delivers object metadata (namespace, bucket, object name) to the function. Ensure the function's dynamic group has `manage objects` and `read objectstorage-namespace` on the bucket compartment.

## IAM Policies (Dynamic Group)

Both functions use Resource Principal in OCI. Create a dynamic group that includes your function and grant it these policies:

**For copyusagereport and xtenancycheck** (general Object Storage access):

```hcl
Allow dynamic-group <dynamic-group-name> to manage objects in compartment <compartment-name>
Allow dynamic-group <dynamic-group-name> to read objectstorage-namespace in compartment <compartment-name>
```

**For xtenancycheck** (to restrict to a specific bucket):

```hcl
Allow dynamic-group <dynamic-group-name> to manage objects in compartment <compartment-name> where target.bucket.name='<bucket-name>'
Allow dynamic-group <dynamic-group-name> to read objectstorage-namespace in compartment <compartment-name>
```
