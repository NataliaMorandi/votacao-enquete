FROM node:20-alpine

WORKDIR /app

COPY package*.json ./
RUN npm install --omit=dev

COPY src ./src

ENV NODE_ENV=production
# Porta interna apenas para o /metrics e /health (não exposta na internet)
EXPOSE 9101

USER node

CMD ["node", "src/index.js"]
