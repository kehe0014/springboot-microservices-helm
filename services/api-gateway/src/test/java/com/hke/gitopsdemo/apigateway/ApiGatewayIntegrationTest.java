package com.hke.gitopsdemo.apigateway;

import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.web.reactive.server.WebTestClient;
import org.springframework.boot.test.autoconfigure.web.reactive.WebFluxTest;

import com.hke.gitopsdemo.apigateway.controller.FallbackController;

@WebFluxTest(controllers = FallbackController.class)
class ApiGatewayIntegrationTest {

    @Autowired
    private WebTestClient webTestClient;

    @Test
    void shouldReturnUserFallbackWhenUserServiceUnavailable() {
        webTestClient.get()
                .uri("/fallback/user")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class)
                .isEqualTo("User Service is temporarily unavailable. Please try again later.");
    }

    @Test
    void shouldReturnProductFallbackWhenProductServiceUnavailable() {
        webTestClient.get()
                .uri("/fallback/product")
                .exchange()
                .expectStatus().isOk()
                .expectBody(String.class)
                .isEqualTo("Product Service is temporarily unavailable. Please try again later.");
    }
}
