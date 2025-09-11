package com.hke.gitopsdemo.product.repository;

import org.springframework.data.jpa.repository.JpaRepository;
import com.hke.gitopsdemo.product.model.Product;

public interface ProductRepository extends JpaRepository<Product, Long> {

}
