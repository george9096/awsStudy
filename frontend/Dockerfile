# --- Build stage ---
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install
COPY . .
RUN npm run build

# --- Runtime stage ---
FROM nginx:1.27-alpine
# nginx 1.19+ 는 /etc/nginx/templates/*.template 을 자동으로 envsubst 후 conf.d 로 복사
COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html
ENV BACKEND_HOST=backend
EXPOSE 80
HEALTHCHECK --interval=30s --timeout=3s CMD wget -qO- http://127.0.0.1/ || exit 1
