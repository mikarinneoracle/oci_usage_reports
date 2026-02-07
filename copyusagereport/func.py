import io
import json
import logging
import os
import base64
import requests
import oci
from datetime import datetime, timedelta
from fdk import response

logger = logging.getLogger()

def handler(ctx, data: io.BytesIO = None):
    processed_files = []
    try:
        cfg = dict(ctx.Config()) if ctx is not None else {}
        reporting_namespace = 'bling'
        
        # Get tenancy_ocid from config or auto-retrieve
        tenancy_ocid = cfg.get('tenancy_ocid')
        
        bucket_name = cfg.get('bucket_name')
        if not bucket_name:
            raise ValueError("Missing required config key 'bucket_name'. Set it with 'fn config function <app> copyusagereport bucket_name <bucket_name>'.")
        
        # Optional parameters for cross-tenancy upload
        secret = cfg.get('secret')
        x_tenancy_par = cfg.get('x-tenancy_par')
        
        # Check if /config exists (OCI CLI config for local testing)
        if os.path.exists('/config'):
            logger.info("Found /config file, using OCI CLI authentication")
            config = oci.config.from_file('/config')
            object_storage = oci.object_storage.ObjectStorageClient(config)
            # Auto-retrieve tenancy_ocid from config if not provided
            if not tenancy_ocid:
                tenancy_ocid = config.get('tenancy')
                logger.info(f"Auto-retrieved tenancy_ocid from CLI config: {tenancy_ocid}")
        else:
            logger.info("No /config file found, using Resource Principal authentication")
            Signer = oci.auth.signers.get_resource_principals_signer()
            object_storage = oci.object_storage.ObjectStorageClient(config={}, signer=Signer)
            # Auto-retrieve tenancy_ocid from signer if not provided
            if not tenancy_ocid:
                try:
                    # Get tenancy OCID from the signer's principal
                    tenancy_ocid = Signer.tenancy_id
                    logger.info(f"Auto-retrieved tenancy_ocid from Resource Principal: {tenancy_ocid}")
                except Exception as ex:
                    logger.warning(f"Could not auto-retrieve tenancy_ocid from Resource Principal: {str(ex)}")
        
        if not tenancy_ocid:
            raise ValueError("Missing required config key 'tenancy_ocid'. Set it with 'fn config function <app> copyusagereport tenancy_ocid <tenancy_ocid>'.")
        
        logger.info(f"Starting report copy process")
        logger.info(f"Configuration - tenancy_ocid: {tenancy_ocid}, bucket_name: {bucket_name}")
        
        # Secret prefix: use when secret is defined (for both in-tenancy and cross-tenancy)
        # so xtenancycheck validation works consistently.
        use_secret_prefix = bool(secret and str(secret).strip())

        # PAR upload: use only when BOTH secret and x-tenancy_par are defined.
        # NOTE: PAR must be created at the bucket root with write privileges, without prefix.
        use_cross_tenancy = (
            bool(x_tenancy_par and str(x_tenancy_par).strip()) and
            bool(secret and str(secret).strip())
        )

        if use_cross_tenancy:
            logger.info(f"Cross-tenancy upload enabled with PAR: {x_tenancy_par[:50]}...")
            logger.info("PAR must be created at bucket root with write privileges, without prefix")
        if use_secret_prefix:
            logger.info("Secret prefix will be added to filenames (enables xtenancycheck for in-tenancy and cross-tenancy)")

        # Days to look back for reports (default 3)
        try:
            days = int(cfg.get('days', 3))
        except (TypeError, ValueError):
            days = 3
        days = max(0, min(days, 31))  # clamp 0-31
        logger.info(f"Looking back {days} day(s) for reports")
        
        report_date = datetime.now() - timedelta(days=days)
        prefix_file = f"FOCUS Reports/{report_date.year}/{report_date.strftime('%m')}/{report_date.strftime('%d')}"
        logger.info(f"Looking for reports with prefix: {prefix_file}")
        logger.info(f"Reporting namespace: {reporting_namespace}")
        logger.info(f"Source bucket OCID: {tenancy_ocid}")
        
        destination_path = '/tmp'
        
        # Get namespace using SDK
        namespace_response = object_storage.get_namespace()
        namespace = namespace_response.data
        logger.info(f"Retrieved namespace: {namespace}")
        
        # List objects in the reporting bucket
        logger.info(f"Listing objects in namespace '{reporting_namespace}', bucket '{tenancy_ocid}', prefix '{prefix_file}'")
        report_bucket_objects = oci.pagination.list_call_get_all_results(
            object_storage.list_objects, 
            reporting_namespace, 
            tenancy_ocid, 
            prefix=prefix_file
        )
        
        object_count = len(report_bucket_objects.data.objects) if report_bucket_objects.data.objects else 0
        logger.info(f"Found {object_count} object(s) matching the prefix")
        
        if object_count == 0:
            logger.warning(f"No objects found with prefix '{prefix_file}' in bucket '{tenancy_ocid}'")
            logger.info("Available prefixes/objects in bucket (first 10):")
            try:
                all_objects = oci.pagination.list_call_get_all_results(
                    object_storage.list_objects,
                    reporting_namespace,
                    tenancy_ocid
                )
                if all_objects.data.objects:
                    for obj in all_objects.data.objects[:10]:
                        logger.info(f"  - {obj.name}")
                else:
                    logger.info("  No objects found in bucket at all")
            except Exception as list_ex:
                logger.error(f"Error listing all objects: {str(list_ex)}")
        
        for o in report_bucket_objects.data.objects:
            logger.info(f"Processing object: {o.name}")
            object_details = object_storage.get_object(reporting_namespace, tenancy_ocid, o.name)
            filename = o.name.rsplit('/', 1)[-1]
            local_file_path = destination_path+'/'+filename
            logger.info(f"Downloading to local path: {local_file_path}")
            
            with open(local_file_path, 'wb') as f:
                for chunk in object_details.data.raw.stream(1024 * 1024, decode_content=False):
                    f.write(chunk)
            
            logger.info(f"Downloaded {filename}, size: {o.size} bytes")
            
            with open(local_file_path, 'rb') as file_content:
                # Build object name
                base_object_name = f"{report_date.year}_{report_date.strftime('%m')}_{report_date.strftime('%d')}_{filename}"
                
                # Add secret prefix if cross-tenancy upload with secret is enabled
                if use_secret_prefix:
                    secret_b64 = base64.b64encode(secret.encode('utf-8')).decode('utf-8')
                    object_name = f"{secret_b64}_{base_object_name}"
                    logger.info(f"Added secret prefix to filename: {object_name}")
                else:
                    object_name = base_object_name
                
                # Upload using cross-tenancy PAR or standard method
                if use_cross_tenancy:
                    logger.info(f"Uploading via cross-tenancy PAR to object '{object_name}'")
                    # Use PAR URL for cross-tenancy upload
                    # NOTE: PAR must be created at bucket root with write privileges, without prefix (directory)
                    # PAR URL format: https://objectstorage.<region>.oraclecloud.com/p/<par_id>/n/<namespace>/b/<bucket>/o/<object>
                    file_content.seek(0)  # Reset file pointer
                    file_data = file_content.read()
                    
                    # Handle both bucket-level PAR (ends with /o/) and object-level PAR
                    # Bucket-level PAR allows writing multiple objects, object-level PAR is for a specific object
                    par_url = x_tenancy_par.rstrip('/')
                    
                    # Check if PAR URL ends with /o/ or /o (bucket-level PAR) or ends with the object name (object-level PAR)
                    if par_url.endswith('/o') or par_url.endswith('/o/'):
                        # Bucket-level PAR - append object name
                        upload_url = f"{par_url}/{object_name}"
                    elif par_url.endswith('/' + object_name):
                        # Object-level PAR - use as-is
                        upload_url = par_url
                    else:
                        # Assume bucket-level PAR and append object name
                        upload_url = f"{par_url}/{object_name}"
                    
                    logger.info(f"Uploading to PAR URL: {upload_url[:100]}...")
                    logger.info(f"File size: {len(file_data)} bytes")
                    
                    # Upload via PAR using PUT request
                    # PAR URLs don't require authentication headers - the URL itself is the authentication
                    headers = {
                        'Content-Type': 'application/octet-stream',
                        'Content-Length': str(len(file_data))
                    }
                    par_response = requests.put(upload_url, data=file_data, headers=headers)
                    par_response.raise_for_status()
                    logger.info(f"Successfully uploaded via PAR: {object_name} (Status: {par_response.status_code})")
                else:
                    logger.info(f"Uploading to destination namespace '{namespace}', bucket '{bucket_name}', object '{object_name}'")
                    object_storage.put_object(
                        namespace_name=namespace,
                        bucket_name=bucket_name,
                        object_name=object_name,
                        put_object_body=file_content
                    )
                    logger.info(f"Successfully uploaded: {object_name}")
                
                processed_files.append({
                    "source": o.name,
                    "destination": object_name,
                    "size": o.size,
                    "cross_tenancy": use_cross_tenancy
                })
        
        result_message = f"Processed {len(processed_files)} file(s) successfully"
        logger.info(result_message)
        
        return response.Response(
            ctx, 
            response_data=json.dumps({
                "message": result_message,
                "files_processed": len(processed_files),
                "files": processed_files,
                "namespace": namespace,
                "source_bucket": tenancy_ocid,
                "destination_bucket": bucket_name
            })
        )
        
    except (Exception, ValueError) as ex:
        error_msg = f'Error processing reports: {str(ex)}'
        logger.error(error_msg, exc_info=True)
        return response.Response(
            ctx,
            response_data=json.dumps({
                "message": "Error processing reports",
                "error": str(ex),
                "files_processed": len(processed_files),
                "files": processed_files
            }),
            status_code=500
        )
