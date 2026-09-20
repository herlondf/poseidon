# spring-boot-starter-web (embedded Tomcat) is resolved from Maven Central at
# build time via pom.xml - nothing framework-related is vendored into this
# repo, only the 4 small files copied below into a standard Maven layout.
FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /build
COPY pom.xml ./
RUN mvn -q -B dependency:go-offline
COPY Application.java src/main/java/com/poseidon/bench/Application.java
COPY BenchController.java src/main/java/com/poseidon/bench/BenchController.java
COPY application.properties src/main/resources/application.properties
COPY large.json src/main/resources/large.json
RUN mvn -q -B package -DskipTests

FROM eclipse-temurin:21-jre
WORKDIR /app
COPY --from=build /build/target/bench.jar ./bench.jar
EXPOSE 8080
CMD ["java", "-jar", "bench.jar"]
