package com.awsstudy.demo.counter;

import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.Map;

@RestController
@RequestMapping("/api/counter")
public class CounterController {

    private static final String KEY = "awsstudy:counter";
    private final StringRedisTemplate redis;

    public CounterController(StringRedisTemplate redis) {
        this.redis = redis;
    }

    @GetMapping
    public Map<String, Object> increment() {
        Long value = redis.opsForValue().increment(KEY);
        return Map.of("counter", value == null ? 0 : value);
    }
}
