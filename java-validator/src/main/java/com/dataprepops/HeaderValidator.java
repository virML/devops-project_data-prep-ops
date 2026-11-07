package com.dataprepops;
import java.nio.file.Files;
import java.nio.file.Path;
import java.io.IOException;

/** A tiny Maven-built Java validation example for VLE-6 continuity. */
public class HeaderValidator {
    public static void main(String[] args) throws IOException {
        if (args.length != 1) throw new IllegalArgumentException("Usage: HeaderValidator file.csv");
        String header = Files.readAllLines(Path.of(args[0])).stream().findFirst().orElse("");
        if (!header.contains(",")) throw new IllegalArgumentException("Expected a CSV header with multiple columns");
        System.out.println("CSV header validation: PASS");
    }
}
