FROM node:22-alpine
WORKDIR /app
COPY package.json server.mjs ./
COPY public ./public
COPY contract ./contract
ENV GANTRY_WEB_HOST=0.0.0.0 GANTRY_WEB_PORT=8788 GANTRY_WEB_DATA_DIR=/data
VOLUME ["/data"]
EXPOSE 8788
USER node
CMD ["node", "server.mjs"]
