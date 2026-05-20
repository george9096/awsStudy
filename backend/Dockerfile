# --- Build stage ---
FROM gradle:8.10-jdk21-alpine AS build
WORKDIR /app
COPY settings.gradle build.gradle ./
COPY src ./src
RUN gradle bootJar --no-daemon

# --- Runtime stage ---
FROM eclipse-temurin:21-jre-alpine
WORKDIR /app
COPY --from=build /app/build/libs/*.jar app.jar
EXPOSE 8080
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0"
ENTRYPOINT ["sh","-c","java $JAVA_OPTS -jar /app/app.jar"]
