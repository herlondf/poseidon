package com.poseidon.bench;

// Minimal Spring Boot contender for the framework comparison: serves the
// three TechEmpower-style endpoints, nothing else - same contract as every
// other contender (/plaintext text, /json json, /json-large ~62KB json,
// port 8080, keep-alive). spring-boot-starter-web (embedded Tomcat) is
// resolved from Maven Central at image-build time via pom.xml (see
// Dockerfile) - only this file, BenchController.java, pom.xml and
// large.json are committed to the repo.

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;

@SpringBootApplication
public class Application {
    public static void main(String[] args) {
        SpringApplication.run(Application.class, args);
    }
}
