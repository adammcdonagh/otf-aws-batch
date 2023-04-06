FROM python:3.10.10-alpine3.17
RUN pip install opentaskpy otf-addons-aws
RUN mkdir /app /logs && ln -s /logs /app/logs
WORKDIR /app