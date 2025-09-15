package com.hke.gitopsdemo.apigateway.controller;

import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

@RestController
@RequestMapping("/fallback")
public class FallbackController {

    @GetMapping("/user")
    public ResponseEntity<String> userFallback() {
        return ResponseEntity.ok("User Service is temporarily unavailable. Please try again later.");
    }

    @GetMapping("/product")
    public ResponseEntity<String> productFallback() {
        return ResponseEntity.ok("Product Service is temporarily unavailable. Please try again later.");
    }
}
