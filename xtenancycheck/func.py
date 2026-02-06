import io
import json
import logging
import os
import base64
import oci
from fdk import response

logger = logging.getLogger()

def handler(ctx, data: io.BytesIO = None):
    """
    Function to validate uploaded files in OCI Object Storage.
    
    This function is triggered by bucket write events and checks if uploaded files
    have the correct secret prefix (base64-encoded secret followed by underscore).
    Files without the correct prefix are logged and deleted.
    """
    try:
        cfg = dict(ctx.Config()) if ctx is not None else {}
        
        # Get secret from configuration
        secret = cfg.get('secret')
        if not secret:
            raise ValueError("Missing required config key 'secret'. Set it with 'fn config function <app> xtenancycheck secret <secret>'.")
        
        logger.info(f"Starting file validation check")
        logger.info(f"Secret configured: {'*' * min(len(secret), 10)}...")
        
        # Parse the event data
        if data is None:
            logger.error("No event data received")
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "No event data received",
                    "status": "error"
                }),
                status_code=400
            )
        
        # Read and decode event data
        try:
            raw_data = data.read()
            logger.info(f"Raw event data length: {len(raw_data)} bytes")
            
            if len(raw_data) == 0:
                logger.error("Empty event data received")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "Empty event data received",
                        "status": "error"
                    }),
                    status_code=400
                )
            
            # Try to decode as UTF-8
            try:
                decoded_data = raw_data.decode('utf-8')
                logger.info(f"Decoded event data (first 500 chars): {decoded_data[:500]}")
            except UnicodeDecodeError as e:
                logger.error(f"Failed to decode event data as UTF-8: {str(e)}")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "Failed to decode event data",
                        "error": str(e),
                        "status": "error"
                    }),
                    status_code=400
                )
            
            # Parse JSON
            try:
                event_data = json.loads(decoded_data)
                logger.info(f"Parsed event data keys: {list(event_data.keys())}")
                if 'data' in event_data:
                    logger.info(f"Event data.data keys: {list(event_data['data'].keys())}")
                    if 'additionalDetails' in event_data.get('data', {}):
                        logger.info(f"Event data.data.additionalDetails keys: {list(event_data['data']['additionalDetails'].keys())}")
            except json.JSONDecodeError as e:
                logger.error(f"Failed to parse JSON: {str(e)}")
                logger.error(f"Data content: {decoded_data[:1000]}")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "Invalid JSON in event data",
                        "error": str(e),
                        "data_preview": decoded_data[:200],
                        "status": "error"
                    }),
                    status_code=400
                )
        except Exception as parse_ex:
            logger.error(f"Error reading/parsing event data: {str(parse_ex)}", exc_info=True)
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "Error parsing event data",
                    "error": str(parse_ex),
                    "status": "error"
                }),
                status_code=400
            )
        
        # Extract object information from event
        # OCI Object Storage events structure:
        # {
        #   "eventType": "com.oraclecloud.objectstorage.createobject",
        #   "data": {
        #     "resourceName": "object-name",  // Just the filename
        #     "additionalDetails": {
        #       "namespace": "namespace",
        #       "bucketName": "bucket-name"
        #     }
        #   }
        # }
        
        event_data_obj = event_data.get('data', {})
        additional_details = event_data_obj.get('additionalDetails', {})
        
        # Extract information from event structure
        object_name = event_data_obj.get('resourceName', '')
        namespace = additional_details.get('namespace', '')
        bucket_name = additional_details.get('bucketName', '')
        
        if not object_name:
            logger.error("No object name (resourceName) found in event data")
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "No object name found in event data",
                    "status": "error"
                }),
                status_code=400
            )
        
        if not namespace:
            logger.error("No namespace found in event data.additionalDetails")
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "No namespace found in event data",
                    "status": "error"
                }),
                status_code=400
            )
        
        if not bucket_name:
            logger.error("No bucketName found in event data.additionalDetails")
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "No bucketName found in event data",
                    "status": "error"
                }),
                status_code=400
            )
        
        logger.info(f"Extracted from event: namespace={namespace}, bucket={bucket_name}, object={object_name}")
        
        # Initialize OCI Object Storage client (needed for deletion)
        if os.path.exists('/config'):
            logger.info("Found /config file, using OCI CLI authentication")
            config = oci.config.from_file('/config')
            object_storage = oci.object_storage.ObjectStorageClient(config)
        else:
            logger.info("No /config file found, using Resource Principal authentication")
            Signer = oci.auth.signers.get_resource_principals_signer()
            object_storage = oci.object_storage.ObjectStorageClient(config={}, signer=Signer)
        
        # Calculate expected secret prefix
        secret_b64 = base64.b64encode(secret.encode('utf-8')).decode('utf-8')
        expected_prefix = f"{secret_b64}_"
        
        logger.info(f"Expected prefix: {expected_prefix[:20]}...")
        logger.info(f"Object name: {object_name}")
        
        # Check if object name (filename) starts with the expected secret prefix
        if not object_name.startswith(expected_prefix):
            logger.warning(f"SECURITY ALERT: Object '{object_name}' does not have correct secret prefix!")
            logger.warning(f"Expected prefix: {expected_prefix[:20]}..., Got: {object_name[:20]}...")
            
            # Validate all required parameters before attempting deletion
            if not namespace or not namespace.strip():
                logger.error(f"Cannot delete file - namespace is empty or None: '{namespace}'")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "File validation failed but cannot delete - namespace is empty",
                        "status": "validation_failed",
                        "object_name": object_name,
                        "namespace": str(namespace) if namespace else "None",
                        "bucket": bucket_name or "missing"
                    }),
                    status_code=200
                )
            
            if not bucket_name or not bucket_name.strip():
                logger.error(f"Cannot delete file - bucket name is empty or None: '{bucket_name}'")
                logger.error(f"Event data keys: {list(event_data.keys())}")
                logger.error(f"Event data.data keys: {list(event_data_obj.keys())}")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "File validation failed but cannot delete - bucket is empty",
                        "status": "validation_failed",
                        "object_name": object_name,
                        "namespace": namespace,
                        "bucket": str(bucket_name) if bucket_name else "None",
                        "event_structure": {
                            "top_level_keys": list(event_data.keys()),
                            "data_keys": list(event_data_obj.keys())
                        }
                    }),
                    status_code=200
                )
            
            if not object_name or not object_name.strip():
                logger.error(f"Cannot delete file - object name is empty or None: '{object_name}'")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "File validation failed but cannot delete - object name is empty",
                        "status": "validation_failed",
                        "object_name": str(object_name) if object_name else "None",
                        "namespace": namespace,
                        "bucket": bucket_name
                    }),
                    status_code=200
                )
            
            # Delete the unauthorized file
            try:
                logger.info(f"Deleting unauthorized file: namespace='{namespace}', bucket='{bucket_name}', object='{object_name}'")
                object_storage.delete_object(
                    namespace_name=namespace.strip(),
                    bucket_name=bucket_name.strip(),
                    object_name=object_name.strip()
                )
                logger.info(f"Successfully deleted unauthorized file: {object_name}")
                
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "File deleted - invalid secret prefix",
                        "status": "deleted",
                        "object_name": object_name,
                        "namespace": namespace,
                        "bucket": bucket_name
                    }),
                    status_code=200
                )
            except Exception as delete_ex:
                logger.error(f"Failed to delete file: {str(delete_ex)}", exc_info=True)
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "File validation failed but deletion error occurred",
                        "status": "error",
                        "object_name": object_name,
                        "namespace": namespace,
                        "bucket": bucket_name,
                        "error": str(delete_ex)
                    }),
                    status_code=500
                )
        else:
            logger.info(f"File '{object_name}' has valid secret prefix - allowing")
            return response.Response(
                ctx,
                response_data=json.dumps({
                    "message": "File validated successfully",
                    "status": "valid",
                    "object_name": object_name,
                    "namespace": namespace,
                    "bucket": bucket_name
                }),
                status_code=200
            )
        
    except (Exception, ValueError) as ex:
        error_msg = f'Error processing file validation: {str(ex)}'
        logger.error(error_msg, exc_info=True)
        return response.Response(
            ctx,
            response_data=json.dumps({
                "message": "Error processing file validation",
                "error": str(ex),
                "status": "error"
            }),
            status_code=500
        )
