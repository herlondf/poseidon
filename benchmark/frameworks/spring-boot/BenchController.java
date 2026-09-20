package com.poseidon.bench;

import java.io.IOException;
import java.io.InputStream;

import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class BenchController {

    private static final byte[] LARGE_JSON = loadLargeJson();

    private static byte[] loadLargeJson() {
        try (InputStream in = BenchController.class.getClassLoader().getResourceAsStream("large.json")) {
            return in.readAllBytes();
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    @GetMapping(value = "/plaintext", produces = MediaType.TEXT_PLAIN_VALUE)
    public String plaintext() {
        return "Hello, World!";
    }

    @GetMapping(value = "/json", produces = MediaType.APPLICATION_JSON_VALUE)
    public String jsonSmall() {
        return "{\"message\":\"Hello, World!\"}";
    }

    @GetMapping(value = "/json-large")
    public ResponseEntity<byte[]> jsonLarge() {
        return ResponseEntity.ok()
                .header(HttpHeaders.CONTENT_TYPE, MediaType.APPLICATION_JSON_VALUE)
                .body(LARGE_JSON);
    }
}
