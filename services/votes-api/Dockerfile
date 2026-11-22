FROM node:20-alpine

WORKDIR /app

# Camada de dependências (cacheável)
COPY package*.json ./
RUN npm install --omit=dev

# Camada de código
COPY src ./src
COPY public ./public

ENV NODE_ENV=production
EXPOSE 3000

# Usuário não-root
USER node

CMD ["node", "src/index.js"]
