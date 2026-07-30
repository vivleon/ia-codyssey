FROM nginx:alpine

LABEL org.opencontainers.image.title="ia-codyssey-web"
LABEL org.opencontainers.image.description="Custom NGINX image for development workstation mission"
LABEL org.opencontainers.image.source="https://github.com/vivleon/ia-codyssey"

ENV APP_ENV=development

COPY app/ /usr/share/nginx/html/

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1
