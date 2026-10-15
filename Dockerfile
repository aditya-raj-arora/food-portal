FROM nginx:1.27-alpine

ARG APP_VERSION=dev

LABEL org.opencontainers.image.title="Online Food Ordering Portal" \
      org.opencontainers.image.version="${APP_VERSION}"

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY index.html styles.css /usr/share/nginx/html/
RUN echo "${APP_VERSION}" > /usr/share/nginx/html/version.txt

EXPOSE 80

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://127.0.0.1/healthz > /dev/null || exit 1
