FROM node:24-alpine AS build
WORKDIR /app
COPY web/admin-ui/package*.json ./
RUN npm ci
COPY web/admin-ui/ ./
RUN npm run build

FROM nginx:1.27-alpine
ENV ADMIN_UI_PORT=8080 \
    GATEWAY_UPSTREAM=http://gateway:8080 \
    CONTROL_PLANE_UPSTREAM=http://control-plane:8081 \
    MOCK_PROVIDER_UPSTREAM=http://mock-provider:18080
COPY web/admin-ui/nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
