#ARG busybox_version=1.32.0

#FROM busybox:${busybox_version}
FROM public.ecr.aws/ubuntu/ubuntu:latest

COPY *.sh /
ENTRYPOINT ["/entrypoint.sh"]
