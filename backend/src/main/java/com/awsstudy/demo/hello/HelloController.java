package com.awsstudy.demo.hello;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.Map;

@RestController
@RequestMapping("/api")
public class HelloController {

    @GetMapping("/hello")
    public Map<String, Object> hello() {
        return Map.of(
                "message", "Hello from awsStudy backend",
                "host", System.getenv().getOrDefault("HOSTNAME", "unknown"),
                "timestamp", OffsetDateTime.now().toString()
        );
    }
}
