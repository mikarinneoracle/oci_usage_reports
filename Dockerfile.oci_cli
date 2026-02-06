FROM fnproject/python:3.11-dev as build-stage
WORKDIR /function
ADD requirements.txt /function/

			RUN pip3 install --target /python/  --no-cache --no-cache-dir -r requirements.txt &&\
			    rm -fr ~/.cache/pip /tmp* requirements.txt func.yaml Dockerfile .venv &&\
			    chmod -R o+r /python
ADD . /function/
RUN rm -fr /function/.pip_cache
FROM fnproject/python:3.11
WORKDIR /function
COPY --from=build-stage /python /python
COPY --from=build-stage /function /function
RUN chmod -R o+r /function
ENV PYTHONPATH=/function:/python
RUN echo "**** WARNING ***"
RUN echo "**** THIS CONTAINER CONTAINS OCI CREDENTIALS - DO NOT DISTRIBUTE ***"
RUN echo "Copy your OCI CLI .oci dir under this dir before running this Dockerfile"
ADD .oci/config /
ADD .oci/oci_api_key.pem /
RUN chmod 777 /config
RUN chmod 777 /oci_api_key.pem
RUN sed -i '/^key_file/d' /config
RUN echo "key_file = /oci_api_key.pem" >> /config
ENTRYPOINT ["/python/bin/fdk", "/function/func.py", "handler"]
