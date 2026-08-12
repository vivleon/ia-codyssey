# 2026-08-12에 검증한 nginx:alpine 멀티 아키텍처 manifest digest입니다.
# 태그의 가독성과 digest의 재현성을 함께 유지합니다.
FROM nginx:alpine@sha256:4a73073bd557c65b759505da037898b61f1be6cbcc3c2c3aeac22d2a470c1752

LABEL org.opencontainers.image.title="ia-codyssey-web"
LABEL org.opencontainers.image.description="Custom NGINX image for development workstation mission"
LABEL org.opencontainers.image.source="https://github.com/vivleon/ia-codyssey"

ENV APP_ENV=development

COPY app/ /usr/share/nginx/html/

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1
