FROM alpine:3.23

RUN echo "https://dl-cdn.alpinelinux.org/alpine/edge/testing/" >> /etc/apk/repositories
RUN apk add --no-cache bash snapcast librespot sed

COPY run.sh /
RUN chmod +x /run.sh
CMD ["/run.sh"]

ENV DEVICE_NAME=Snapcast
EXPOSE 1704/tcp 1705/tcp
