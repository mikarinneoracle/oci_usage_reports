import io
import json
import logging
import os
import oci
from datetime import datetime, timedelta
from fdk import response

logger = logging.getLogger()

def handler(ctx, data: io.BytesIO = None):
    processed_files = []
    try:
        cfg = dict(ctx.Config()) if ctx is not None else {}
        reporting_namespace = 'bling'
        tenancy_ocid = cfg.get('tenancy_ocid')
        if not tenancy_ocid:
            raise ValueError("Missing required config key 'tenancy_ocid'. Set it with 'fn config function <app> copyusagereport tenancy_ocid <tenancy_ocid>'.")
        bucket_name = cfg.get('bucket_name')
        if not bucket_name:
            raise ValueError("Missing required config key 'bucket_name'. Set it with 'fn config function <app> copyusagereport bucket_name <bucket_name>'.")
        
        logger.info(f"Starting report copy process")
        logger.info(f"Configuration - tenancy_ocid: {tenancy_ocid}, bucket_name: {bucket_name}")
        
        yesterday = datetime.now() - timedelta(days=3)
        prefix_file = f"FOCUS Reports/{yesterday.year}/{yesterday.strftime('%m')}/{yesterday.strftime('%d')}"
        logger.info(f"Looking for reports with prefix: {prefix_file}")
        logger.info(f"Reporting namespace: {reporting_namespace}")
        logger.info(f"Source bucket OCID: {tenancy_ocid}")
        
        destination_path = '/tmp'
        
        # Check if /config exists (OCI CLI config for local testing)
        if os.path.exists('/config'):
            logger.info("Found /config file, using OCI CLI authentication")
            config = oci.config.from_file('/config')
            object_storage = oci.object_storage.ObjectStorageClient(config)
        else:
            logger.info("No /config file found, using Resource Principal authentication")
            Signer = oci.auth.signers.get_resource_principals_signer()
            object_storage = oci.object_storage.ObjectStorageClient(config={}, signer=Signer)
        
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
                object_name = f"{yesterday.year}_{yesterday.strftime('%m')}_{yesterday.strftime('%d')}_{filename}"
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
                    "size": o.size
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
