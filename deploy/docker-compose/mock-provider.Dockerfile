FROM node:24-alpine
WORKDIR /app
COPY deploy/mock-provider/server.mjs ./server.mjs
EXPOSE 18080
CMD ["node", "server.mjs"]
