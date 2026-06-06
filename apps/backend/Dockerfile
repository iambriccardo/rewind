FROM node:22-alpine

WORKDIR /app

ENV NODE_ENV=development
ENV HOST=0.0.0.0
ENV PORT=8787

COPY package*.json ./
RUN npm ci

COPY apps/backend/tsconfig.json ./apps/backend/tsconfig.json
COPY apps/backend/src ./apps/backend/src

EXPOSE 8787

CMD ["npm", "run", "start:backend"]
