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
                logger.info(f"Parsed event data: {json.dumps(event_data, indent=2)}")
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
        # OCI Object Storage events can have different structures:
        # Structure 1 (Event Service):
        # {
        #   "eventType": "com.oraclecloud.objectstorage.createobject",
        #   "data": {
        #     "resourceName": "namespace/bucket/object-name",
        #     "additionalDetails": {...}
        #   }
        # }
        # Structure 2 (Direct invocation with JSON):
        # {
        #   "namespace": "namespace",
        #   "bucket": "bucket-name",
        #   "object": "object-name"
        # }
        
        # Try Structure 1 first (Event Service format)
        event_type = event_data.get('eventType', '')
        event_data_obj = event_data.get('data', {})
        resource_name = event_data_obj.get('resourceName', '')
        
        # Initialize variables
        namespace = None
        bucket_name = None
        object_name = None
        
        # If Structure 1 has resourceName, parse it
        if resource_name:
            # Parse resource name: namespace/bucket/object-name
            parts = resource_name.split('/', 2)
            if len(parts) >= 3:
                namespace = parts[0]
                bucket_name = parts[1]
                object_name = parts[2]
                logger.info(f"Extracted from resourceName: namespace={namespace}, bucket={bucket_name}, object={object_name}")
            else:
                logger.warning(f"Invalid resourceName format: {resource_name}")
        
        # If Structure 1 didn't work, try Structure 2 (direct format)
        if not (namespace and bucket_name and object_name):
            logger.info("Trying alternative event structure (direct format)")
            namespace = event_data.get('namespace', '')
            bucket_name = event_data.get('bucket', '')
            object_name = event_data.get('object', '')
            
            if namespace and bucket_name and object_name:
                logger.info(f"Using direct format: namespace={namespace}, bucket={bucket_name}, object={object_name}")
            else:
                logger.error("Could not find object information in either event format")
                logger.error(f"Event data structure: {json.dumps(event_data, indent=2)}")
                return response.Response(
                    ctx,
                    response_data=json.dumps({
                        "message": "Could not extract object information from event",
                        "event_keys": list(event_data.keys()),
                        "status": "error"
                    }),
                    status_code=400
                )
        
        logger.info(f"Processing object: namespace={namespace}, bucket={bucket_name}, object={object_name}")
        
        # Calculate expected secret prefix
        secret_b64 = base64.b64encode(secret.encode('utf-8')).decode('utf-8')
        expected_prefix = f"{secret_b64}_"
        
        logger.info(f"Expected prefix: {expected_prefix[:20]}...")
        logger.info(f"Object name: {object_name}")
        
        # Check if object name starts with the expected prefix
        if not object_name.startswith(expected_prefix):
            logger.warning(f"SECURITY ALERT: Object '{object_name}' does not have correct secret prefix!")
            logger.warning(f"Expected prefix: {expected_prefix[:20]}..., Got: {object_name[:20]}...")
            
            # Initialize OCI Object Storage client
            if os.path.exists('/config'):
                logger.info("Found /config file, using OCI CLI authentication")
                config = oci.config.from_file('/config')
                object_storage = oci.object_storage.ObjectStorageClient(config)
            else:
                logger.info("No /config file found, using Resource Principal authentication")
                Signer = oci.auth.signers.get_resource_principals_signer()
                object_storage = oci.object_storage.ObjectStorageClient(config={}, signer=Signer)
            
            # Delete the unauthorized file
            try:
                logger.info(f"Deleting unauthorized file: {object_name}")
                object_storage.delete_object(
                    namespace_name=namespace,
                    bucket_name=bucket_name,
                    object_name=object_name
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
